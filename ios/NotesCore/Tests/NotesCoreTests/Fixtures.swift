import Foundation
@testable import NotesCore

enum Fixtures {
    static let base = Date(timeIntervalSince1970: 1_793_000_000)

    static func time(_ seconds: Double) -> Date {
        Timestamp.rounded(base.addingTimeInterval(seconds))
    }

    static func stroke(_ id: String, at seconds: Double = 0, device: String = "ipad-01", order: Int = 0, tool: Tool = .pen, deleted: Bool = false) -> Element {
        var element = Element.stroke(
            id: id,
            tool: tool,
            color: "#1A1A1A",
            width: 0.5,
            points: [Point(x: 10, y: 10), Point(x: 12.5, y: 11.25)],
            order: order,
            updated: time(seconds),
            device: device
        )
        element.deleted = deleted
        return element
    }

    static func text(_ id: String, _ content: String, at seconds: Double, device: String) -> Element {
        Element.text(id: id, content: content, box: TextBox(x: 20, y: 30, width: 80), fontSize: 4.2, color: "#1A1A1A", order: 0, updated: time(seconds), device: device)
    }

    static func page(_ id: String = "p_01TEST", notebook: String = "nb_01TEST", elements: [Element] = [], extent: Extent = .single, at seconds: Double = 0, device: String = "ipad-01") -> Page {
        Page(header: PageHeader(id: id, notebook: notebook, updated: time(seconds), device: device, extent: extent), elements: elements)
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-core-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class MockRemote: GitRemote {
    struct StoredCommit {
        var parent: String?
        var files: [String: String]
    }

    var blobs: [String: Data] = [:]
    var commits: [String: StoredCommit] = [:]
    var branches: [String: String] = [:]
    var rejectionsRemaining = 0
    var isUnauthorized = false
    var beforeMove: (() -> Void)?
    private var counter = 0

    func headCommit(branch: String) async throws -> String? {
        if isUnauthorized { throw RemoteError.unauthorized }
        return branches[branch]
    }

    func initialize(branch: String) async throws -> String {
        let sha = nextSha("commit")
        commits[sha] = StoredCommit(parent: nil, files: [:])
        branches[branch] = sha
        return sha
    }

    func files(commit: String) async throws -> [String: String] {
        guard let stored = commits[commit] else { throw RemoteError.notFound }
        return stored.files
    }

    func blob(sha: String) async throws -> Data {
        guard let data = blobs[sha] else { throw RemoteError.notFound }
        return data
    }

    func commit(files: [String: Data], parent: String, message: String) async throws -> CommitResult {
        guard let parentCommit = commits[parent] else { throw RemoteError.notFound }
        var tree = parentCommit.files
        var created: [String: String] = [:]
        for (path, data) in files {
            let sha = storeBlob(data)
            tree[path] = sha
            created[path] = sha
        }
        let sha = nextSha("commit")
        commits[sha] = StoredCommit(parent: parent, files: tree)
        return CommitResult(sha: sha, blobs: created)
    }

    func moveBranch(_ branch: String, to commit: String) async throws {
        beforeMove?()
        beforeMove = nil
        if rejectionsRemaining > 0 {
            rejectionsRemaining -= 1
            throw RemoteError.rejected
        }
        guard let current = branches[branch], commits[commit]?.parent == current else {
            throw RemoteError.rejected
        }
        branches[branch] = commit
    }

    func writeExternally(branch: String, files: [String: Data]) {
        let parent = branches[branch]
        var tree = parent.flatMap { commits[$0]?.files } ?? [:]
        for (path, data) in files {
            tree[path] = storeBlob(data)
        }
        let sha = nextSha("commit")
        commits[sha] = StoredCommit(parent: parent, files: tree)
        branches[branch] = sha
    }

    func file(_ path: String, branch: String = "main") -> Data? {
        guard let head = branches[branch], let sha = commits[head]?.files[path] else { return nil }
        return blobs[sha]
    }

    private func storeBlob(_ data: Data) -> String {
        if let existing = blobs.first(where: { $0.value == data })?.key {
            return existing
        }
        let sha = nextSha("blob")
        blobs[sha] = data
        return sha
    }

    private func nextSha(_ kind: String) -> String {
        counter += 1
        return "\(kind)-\(counter)"
    }
}
