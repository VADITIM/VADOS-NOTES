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
    public var fetchedAssets: [String]
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
        var report = SyncReport(pulledPaths: [], pushedPaths: [], blockedPaths: [], fetchedAssets: [], attempts: 0, commit: nil)
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
                report.fetchedAssets = try await fetchMissingAssets()
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
        guard head != snapshot.state.head || snapshot.state.assetsListed != true else { return head }

        let remoteFiles = try await remote.files(commit: head)
        var blobs = snapshot.state.blobs
        var blocked = snapshot.state.blocked
        for (path, sha) in remoteFiles.sorted(by: { $0.key < $1.key }) {
            if RepositoryPath.assetIdentifier(at: path) != nil {
                blobs[path] = sha
                continue
            }
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
            state.assetsListed = true
        }
        store.rebuild()
        return head
    }

    private func push(onto head: String) async throws -> (paths: [String], commit: String)? {
        let entries = store.journal.entries
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

        let assetFiles = pendingAssets()
        files.merge(assetFiles) { page, _ in page }

        guard !files.isEmpty else {
            try store.journal.remove(sequences: settledSequences)
            return nil
        }

        let pageCount = files.keys.filter { $0.contains("/pages/") }.count
        var message = "Sync \(pageCount) page\(pageCount == 1 ? "" : "s")"
        if !assetFiles.isEmpty {
            message += " and \(assetFiles.count) asset\(assetFiles.count == 1 ? "" : "s")"
        }
        message += " from \(store.device)"
        let result = try await remote.commit(files: files, parent: head, message: message)
        try await remote.moveBranch(branch, to: result.sha)

        let snapshot = store.snapshot
        for (path, data) in files where assetFiles[path] == nil {
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

    private func pendingAssets() -> [String: Data] {
        var files: [String: Data] = [:]
        let assets = store.assets
        for asset in store.referencedAssets {
            guard let path = RepositoryPath.asset(asset), store.syncState.blobs[path] == nil else { continue }
            guard let byteCount = assets.byteCount(of: asset), byteCount <= assets.byteLimit else { continue }
            guard let data = assets.data(for: asset), AssetStore.identifier(for: data) == asset else { continue }
            files[path] = data
        }
        return files
    }

    private func fetchMissingAssets() async throws -> [String] {
        var fetched: [String] = []
        for asset in store.referencedAssets.sorted() where !store.assets.contains(asset) {
            guard let path = RepositoryPath.asset(asset), let sha = store.syncState.blobs[path] else { continue }
            let data: Data
            do {
                data = try await remote.blob(sha: sha)
            } catch RemoteError.notFound {
                continue
            }
            if try store.assets.store(data, as: asset) {
                fetched.append(asset)
            }
        }
        return fetched
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
