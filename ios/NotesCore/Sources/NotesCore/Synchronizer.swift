import Foundation

public enum RemoteError: Error, Equatable {
    case rejected
    case unauthorized
    case notFound
    case server(status: Int, message: String)
    case transport(String)
}

public struct CommitResult: Equatable, Sendable {
    public var sha: String
    public var blobs: [String: String]

    public init(sha: String, blobs: [String: String]) {
        self.sha = sha
        self.blobs = blobs
    }
}

public protocol GitRemote: AnyObject {
    func headCommit(branch: String) async throws -> String?
    func initialize(branch: String) async throws -> String
    func files(commit: String) async throws -> [String: String]
    func blob(sha: String) async throws -> Data
    func commit(files: [String: Data], parent: String, message: String) async throws -> CommitResult
    func moveBranch(_ branch: String, to commit: String) async throws
}

public enum SyncError: Error, Equatable {
    case gaveUp(attempts: Int)
    case remote(RemoteError)
}

public struct SyncReport: Equatable, Sendable {
    public var pulledPaths: [String]
    public var pushedPaths: [String]
    public var blockedPaths: [String]
    public var attempts: Int
    public var commit: String?
}

public final class Synchronizer {
    public let branch: String
    private let store: NotesStore
    private let remote: GitRemote
    private let backoff: [Double]
    private let sleep: (Double) async throws -> Void

    public static let defaultBackoff: [Double] = [1, 2, 4, 8, 16, 30]

    public init(
        store: NotesStore,
        remote: GitRemote,
        branch: String = "main",
        backoff: [Double] = Synchronizer.defaultBackoff,
        sleep: @escaping (Double) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    ) {
        self.store = store
        self.remote = remote
        self.branch = branch
        self.backoff = backoff
        self.sleep = sleep
    }

    public func synchronize() async throws -> SyncReport {
        var report = SyncReport(pulledPaths: [], pushedPaths: [], blockedPaths: [], attempts: 0, commit: nil)
        var attempt = 0
        while true {
            attempt += 1
            report.attempts = attempt
            do {
                let head = try await pull(into: &report)
                if let pushed = try await push(onto: head) {
                    report.pushedPaths = pushed.paths
                    report.commit = pushed.commit
                }
                report.blockedPaths = Array(store.blockedPaths.keys).sorted()
                let syncedAt = store.timestamp()
                try store.snapshot.update { $0.lastSynced = syncedAt }
                return report
            } catch RemoteError.rejected {
                guard attempt <= backoff.count else {
                    throw SyncError.gaveUp(attempts: attempt)
                }
                try await sleep(backoff[attempt - 1])
            } catch let error as RemoteError {
                throw SyncError.remote(error)
            }
        }
    }

    private func pull(into report: inout SyncReport) async throws -> String {
        var head = try await remote.headCommit(branch: branch)
        if head == nil {
            head = try await remote.initialize(branch: branch)
        }
        guard let head else { throw RemoteError.notFound }
        let snapshot = store.snapshot
        guard head != snapshot.state.head else { return head }

        let remoteFiles = try await remote.files(commit: head)
        var blobs = snapshot.state.blobs
        var blocked = snapshot.state.blocked
        for (path, sha) in remoteFiles.sorted(by: { $0.key < $1.key }) {
            guard RepositoryPath.kind(of: path) != nil, blobs[path] != sha else { continue }
            let data = try await remote.blob(sha: sha)
            blobs[path] = sha
            switch classify(data, at: path) {
            case .valid:
                try snapshot.write(data, at: path)
                blocked[path] = nil
                report.pulledPaths.append(path)
            case .blocked(let reason):
                blocked[path] = reason
            }
        }
        let pulledBlobs = blobs
        let pulledBlocked = blocked
        try snapshot.update { state in
            state.head = head
            state.blobs = pulledBlobs
            state.blocked = pulledBlocked
        }
        store.rebuild()
        return head
    }

    private func push(onto head: String) async throws -> (paths: [String], commit: String)? {
        let entries = store.journal.entries
        guard !entries.isEmpty else { return nil }

        var sequencesByPath: [String: Set<Int>] = [:]
        var orphanSequences = Set<Int>()
        for entry in entries {
            if let path = store.path(for: entry.change) {
                sequencesByPath[path, default: []].insert(entry.sequence)
            } else {
                orphanSequences.insert(entry.sequence)
            }
        }

        var files: [String: Data] = [:]
        var settledSequences = orphanSequences
        for (path, sequences) in sequencesByPath {
            if store.blockedPaths[path] != nil { continue }
            guard let data = try store.encodedFile(at: path) else {
                settledSequences.formUnion(sequences)
                continue
            }
            if data == store.snapshot.data(at: path) {
                settledSequences.formUnion(sequences)
            } else {
                files[path] = data
            }
        }

        guard !files.isEmpty else {
            try store.journal.remove(sequences: settledSequences)
            return nil
        }

        let pageCount = files.keys.filter { $0.contains("/pages/") }.count
        let message = "Sync \(pageCount) page\(pageCount == 1 ? "" : "s") from \(store.device)"
        let result = try await remote.commit(files: files, parent: head, message: message)
        try await remote.moveBranch(branch, to: result.sha)

        let snapshot = store.snapshot
        for (path, data) in files {
            try snapshot.write(data, at: path)
        }
        try snapshot.update { state in
            state.head = result.sha
            for (path, sha) in result.blobs {
                state.blobs[path] = sha
            }
        }
        for path in files.keys {
            settledSequences.formUnion(sequencesByPath[path] ?? [])
        }
        try store.journal.remove(sequences: settledSequences)
        store.rebuild()
        return (files.keys.sorted(), result.sha)
    }

    enum Classification {
        case valid
        case blocked(BlockReason)
    }

    private func classify(_ data: Data, at path: String) -> Classification {
        do {
            switch RepositoryPath.kind(of: path) {
            case .notebook:
                _ = try PageCodec.decodeNotebook(data)
            case .page:
                _ = try PageCodec.decodePage(data)
            case nil:
                return .valid
            }
            return .valid
        } catch CodecError.unsupportedSchemaVersion {
            return .blocked(.unsupportedVersion)
        } catch {
            return .blocked(.corruptRemote)
        }
    }
}
