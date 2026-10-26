import Foundation

public enum Change: Codable, Equatable, Sendable {
    case notebook(Notebook)
    case page(PageHeader)
    case element(pageId: String, element: Element)

    public func path(notebookOf pageNotebook: (String) -> String?) -> String? {
        switch self {
        case .notebook(let notebook):
            return RepositoryPath.notebook(notebook.id)
        case .page(let header):
            return RepositoryPath.page(notebook: header.notebook, page: header.id)
        case .element(let pageId, _):
            guard let notebookId = pageNotebook(pageId) else { return nil }
            return RepositoryPath.page(notebook: notebookId, page: pageId)
        }
    }
}

public struct JournalEntry: Codable, Equatable, Sendable {
    public var sequence: Int
    public var device: String
    public var timestamp: Date
    public var change: Change
}

public final class Journal {
    public let fileURL: URL
    public private(set) var entries: [JournalEntry] = []
    public private(set) var skippedLineCount = 0
    private var nextSequence = 1
    private let encoder = PageCodec.makeEncoder()
    private let decoder = PageCodec.makeDecoder()

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let entry = try? decoder.decode(JournalEntry.self, from: Data(line)) {
                    entries.append(entry)
                } else {
                    skippedLineCount += 1
                }
            }
        } else {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        nextSequence = (entries.map(\.sequence).max() ?? 0) + 1
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var lastSequence: Int? {
        entries.last?.sequence
    }

    @discardableResult
    public func append(_ change: Change, device: String, timestamp: Date) throws -> JournalEntry {
        let entry = JournalEntry(sequence: nextSequence, device: device, timestamp: timestamp, change: change)
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        entries.append(entry)
        nextSequence += 1
        return entry
    }

    public func remove(sequences: Set<Int>) throws {
        guard !sequences.isEmpty else { return }
        let remaining = entries.filter { !sequences.contains($0.sequence) }
        var data = Data()
        for entry in remaining {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: fileURL, options: .atomic)
        entries = remaining
    }
}
