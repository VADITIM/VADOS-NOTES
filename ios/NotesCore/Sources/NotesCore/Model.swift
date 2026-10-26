import Foundation

public enum Layer: String, Codable, CaseIterable, Sendable {
    case importLayer = "import"
    case marker
    case ink
    case text
    case overlay

    public var rank: Int {
        switch self {
        case .importLayer: return 1
        case .marker: return 2
        case .ink: return 3
        case .text: return 4
        case .overlay: return 5
        }
    }
}

public enum ElementType: String, Codable, Sendable {
    case stroke
    case text
    case importPage = "import"
}

public enum Tool: String, Codable, CaseIterable, Sendable {
    case pen
    case pencil
    case marker

    public var layer: Layer {
        self == .marker ? .marker : .ink
    }
}

public struct Point: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}

public struct Extent: Codable, Equatable, Hashable, Sendable {
    public var columns: Int
    public var rows: Int

    public static let single = Extent(columns: 1, rows: 1)

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case columns = "cols"
        case rows
    }

    public var cellCount: Int {
        columns * rows
    }

    public func doublingColumns() -> Extent {
        Extent(columns: columns * 2, rows: rows)
    }

    public func doublingRows() -> Extent {
        Extent(columns: columns, rows: rows * 2)
    }

    public func union(_ other: Extent) -> Extent {
        Extent(columns: max(columns, other.columns), rows: max(rows, other.rows))
    }
}

public struct TextBox: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double

    public init(x: Double, y: Double, width: Double) {
        self.x = x
        self.y = y
        self.width = width
    }
}

public struct Placement: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double

    public init(x: Double, y: Double, scale: Double) {
        self.x = x
        self.y = y
        self.scale = scale
    }
}

public enum Fit: String, Codable, Sendable {
    case original
    case fitCell = "fit_cell"
    case fitWidth = "fit_width"
}

public struct Element: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: ElementType
    public var layer: Layer
    public var order: Int
    public var tool: Tool?
    public var color: String?
    public var width: Double?
    public var points: [Point]?
    public var content: String?
    public var box: TextBox?
    public var fontSize: Double?
    public var asset: String?
    public var sourcePage: Int?
    public var sourceSizeMillimetres: [Double]?
    public var placement: Placement?
    public var fit: Fit?
    public var updated: Date
    public var device: String
    public var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case layer
        case order
        case tool
        case color
        case width
        case points
        case content
        case box
        case fontSize = "font_size"
        case asset
        case sourcePage = "source_page"
        case sourceSizeMillimetres = "source_size_mm"
        case placement
        case fit
        case updated
        case device
        case deleted
    }

    public static func stroke(id: String, tool: Tool, color: String, width: Double, points: [Point], order: Int, updated: Date, device: String) -> Element {
        Element(id: id, type: .stroke, layer: tool.layer, order: order, tool: tool, color: color, width: width, points: points, updated: updated, device: device)
    }

    public static func text(id: String, content: String, box: TextBox, fontSize: Double, color: String, order: Int, updated: Date, device: String) -> Element {
        Element(id: id, type: .text, layer: .text, order: order, color: color, content: content, box: box, fontSize: fontSize, updated: updated, device: device)
    }

    public init(
        id: String,
        type: ElementType,
        layer: Layer,
        order: Int,
        tool: Tool? = nil,
        color: String? = nil,
        width: Double? = nil,
        points: [Point]? = nil,
        content: String? = nil,
        box: TextBox? = nil,
        fontSize: Double? = nil,
        asset: String? = nil,
        sourcePage: Int? = nil,
        sourceSizeMillimetres: [Double]? = nil,
        placement: Placement? = nil,
        fit: Fit? = nil,
        updated: Date,
        device: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.type = type
        self.layer = layer
        self.order = order
        self.tool = tool
        self.color = color
        self.width = width
        self.points = points
        self.content = content
        self.box = box
        self.fontSize = fontSize
        self.asset = asset
        self.sourcePage = sourcePage
        self.sourceSizeMillimetres = sourceSizeMillimetres
        self.placement = placement
        self.fit = fit
        self.updated = updated
        self.device = device
        self.deleted = deleted
    }

    public func tombstone(at date: Date, device: String) -> Element {
        var copy = self
        copy.deleted = true
        copy.updated = date
        copy.device = device
        return copy
    }

    public static func isOrderedBefore(_ first: Element, _ second: Element) -> Bool {
        if first.layer.rank != second.layer.rank {
            return first.layer.rank < second.layer.rank
        }
        if first.order != second.order {
            return first.order < second.order
        }
        return first.id < second.id
    }
}

public struct PageHeader: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var notebook: String
    public var updated: Date
    public var device: String
    public var deleted: Bool
    public var extent: Extent

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case notebook
        case updated
        case device
        case deleted
        case extent
    }

    public init(schemaVersion: Int = Page.currentSchemaVersion, id: String, notebook: String, updated: Date, device: String, deleted: Bool = false, extent: Extent = .single) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.notebook = notebook
        self.updated = updated
        self.device = device
        self.deleted = deleted
        self.extent = extent
    }
}

public struct Page: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var notebook: String
    public var updated: Date
    public var device: String
    public var deleted: Bool
    public var extent: Extent
    public var elements: [Element]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case notebook
        case updated
        case device
        case deleted
        case extent
        case elements
    }

    public init(header: PageHeader, elements: [Element] = []) {
        schemaVersion = header.schemaVersion
        id = header.id
        notebook = header.notebook
        updated = header.updated
        device = header.device
        deleted = header.deleted
        extent = header.extent
        self.elements = elements
    }

    public var header: PageHeader {
        PageHeader(schemaVersion: schemaVersion, id: id, notebook: notebook, updated: updated, device: device, deleted: deleted, extent: extent)
    }

    public var liveElements: [Element] {
        elements.filter { !$0.deleted }.sorted(by: Element.isOrderedBefore)
    }

    public func element(withId id: String) -> Element? {
        elements.first { $0.id == id }
    }

    public func nextOrder(in layer: Layer) -> Int {
        (elements.filter { $0.layer == layer }.map(\.order).max() ?? -1) + 1
    }
}

public struct Notebook: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var updated: Date
    public var device: String
    public var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case title
        case updated
        case device
        case deleted
    }

    public init(schemaVersion: Int = Notebook.currentSchemaVersion, id: String, title: String, updated: Date, device: String, deleted: Bool = false) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.updated = updated
        self.device = device
        self.deleted = deleted
    }
}

public enum RepositoryPath {
    public static let notebooksDirectory = "notebooks"

    public static func notebook(_ notebookId: String) -> String {
        "\(notebooksDirectory)/\(notebookId)/notebook.json"
    }

    public static func page(notebook notebookId: String, page pageId: String) -> String {
        "\(notebooksDirectory)/\(notebookId)/pages/\(pageId).json"
    }

    public enum Kind: Equatable {
        case notebook(notebookId: String)
        case page(notebookId: String, pageId: String)
    }

    public static func kind(of path: String) -> Kind? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == notebooksDirectory else { return nil }
        if parts.count == 3, parts[2] == "notebook.json" {
            return .notebook(notebookId: parts[1])
        }
        if parts.count == 4, parts[2] == "pages", parts[3].hasSuffix(".json") {
            return .page(notebookId: parts[1], pageId: String(parts[3].dropLast(".json".count)))
        }
        return nil
    }
}
