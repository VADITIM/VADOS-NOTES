import Foundation

public enum BlockReason: String, Codable, Equatable, Sendable {
    case corruptRemote = "corrupt_remote"
    case unsupportedVersion = "unsupported_version"
}

public struct SyncState: Codable, Equatable, Sendable {
    public var head: String?
    public var blobs: [String: String]
    public var blocked: [String: BlockReason]
    public var lastSynced: Date?

    public static let empty = SyncState(head: nil, blobs: [:], blocked: [:], lastSynced: nil)
}

final class Snapshot {
    let directory: URL
    private(set) var state: SyncState
    private(set) var notebooks: [String: Notebook] = [:]
    private(set) var pages: [String: Page] = [:]
    private let stateURL: URL

    init(directory: URL) throws {
        self.directory = directory
        stateURL = directory.appendingPathComponent("sync-state.json")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateURL), let decoded = try? PageCodec.makeDecoder().decode(SyncState.self, from: data) {
            state = decoded
        } else {
            state = .empty
        }
        loadFiles()
    }

    func data(at path: String) -> Data? {
        try? Data(contentsOf: fileURL(for: path))
    }

    func write(_ data: Data, at path: String) throws {
        let url = fileURL(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        absorb(data, at: path)
    }

    func update(_ change: (inout SyncState) -> Void) throws {
        change(&state)
        let encoder = PageCodec.makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func fileURL(for path: String) -> URL {
        path.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
    }

    private func loadFiles() {
        let root = directory.appendingPathComponent(RepositoryPath.notebooksDirectory)
        guard let notebookDirectories = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for notebookId in notebookDirectories {
            let notebookPath = RepositoryPath.notebook(notebookId)
            if let data = data(at: notebookPath) {
                absorb(data, at: notebookPath)
            }
            let pagesURL = root.appendingPathComponent(notebookId).appendingPathComponent("pages")
            let pageFiles = (try? FileManager.default.contentsOfDirectory(atPath: pagesURL.path)) ?? []
            for file in pageFiles where file.hasSuffix(".json") {
                let pageId = String(file.dropLast(".json".count))
                let pagePath = RepositoryPath.page(notebook: notebookId, page: pageId)
                if let data = data(at: pagePath) {
                    absorb(data, at: pagePath)
                }
            }
        }
    }

    private func absorb(_ data: Data, at path: String) {
        switch RepositoryPath.kind(of: path) {
        case .notebook:
            if let notebook = try? PageCodec.decodeNotebook(data) {
                notebooks[notebook.id] = notebook
            }
        case .page:
            if let page = try? PageCodec.decodePage(data) {
                pages[page.id] = page
            }
        case nil:
            break
        }
    }
}

public final class NotesStore {
    public let device: String
    public let journal: Journal
    public private(set) var notebooks: [String: Notebook] = [:]
    public private(set) var pages: [String: Page] = [:]
    let snapshot: Snapshot
    private let now: () -> Date

    public init(directory: URL, device: String, now: @escaping () -> Date = Timestamp.now) throws {
        self.device = device
        self.now = now
        snapshot = try Snapshot(directory: directory.appendingPathComponent("synced"))
        journal = try Journal(fileURL: directory.appendingPathComponent("journal.jsonl"))
        rebuild()
    }

    public var syncState: SyncState {
        snapshot.state
    }

    public var blockedPaths: [String: BlockReason] {
        snapshot.state.blocked
    }

    public var liveNotebooks: [Notebook] {
        notebooks.values.filter { !$0.deleted }.sorted { $0.id < $1.id }
    }

    public func livePages(in notebookId: String) -> [Page] {
        pages.values.filter { $0.notebook == notebookId && !$0.deleted }.sorted { $0.id < $1.id }
    }

    public func isReadOnly(pageId: String) -> Bool {
        guard let page = pages[pageId] else { return false }
        return snapshot.state.blocked[RepositoryPath.page(notebook: page.notebook, page: page.id)] != nil
    }

    public func timestamp() -> Date {
        now()
    }

    public func apply(_ change: Change) throws {
        try journal.append(change, device: device, timestamp: now())
        integrate(change)
    }

    public func path(for change: Change) -> String? {
        change.path { [pages] pageId in pages[pageId]?.notebook }
    }

    public func encodedFile(at path: String) throws -> Data? {
        switch RepositoryPath.kind(of: path) {
        case .notebook(let notebookId):
            guard let notebook = notebooks[notebookId] else { return nil }
            return try PageCodec.encodeNotebook(notebook)
        case .page(_, let pageId):
            guard let page = pages[pageId] else { return nil }
            return try PageCodec.encodePage(page)
        case nil:
            return nil
        }
    }

    func rebuild() {
        notebooks = snapshot.notebooks
        pages = snapshot.pages
        for entry in journal.entries {
            integrate(entry.change)
        }
    }

    private func integrate(_ change: Change) {
        switch change {
        case .notebook(let notebook):
            if let existing = notebooks[notebook.id] {
                notebooks[notebook.id] = Merge.notebook(existing, notebook)
            } else {
                notebooks[notebook.id] = notebook
            }
        case .page(let header):
            if let existing = pages[header.id] {
                pages[header.id] = Page(header: Merge.header(existing.header, header), elements: existing.elements)
            } else {
                pages[header.id] = Page(header: header)
            }
        case .element(let pageId, let element):
            guard var page = pages[pageId] else { return }
            if let index = page.elements.firstIndex(where: { $0.id == element.id }) {
                page.elements[index] = Merge.element(page.elements[index], element)
            } else {
                let index = page.elements.firstIndex { Element.isOrderedBefore(element, $0) } ?? page.elements.endIndex
                page.elements.insert(element, at: index)
            }
            if Merge.isNewer(element.updated, element.device, than: page.updated, page.device) {
                page.updated = element.updated
                page.device = element.device
            }
            pages[pageId] = page
        }
    }
}
