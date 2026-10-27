import Foundation

public enum CodecError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case malformed(String)
    case invalid(String)
}

public enum PageCodec {
    struct VersionProbe: Decodable {
        let schemaVersion: Int?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom(Timestamp.encode)
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Timestamp.decode)
        return decoder
    }

    public static func decodePage(_ data: Data) throws -> Page {
        try checkVersion(data, supported: Page.currentSchemaVersion)
        let page: Page
        do {
            page = try makeDecoder().decode(Page.self, from: data)
        } catch {
            throw CodecError.malformed(String(describing: error))
        }
        try validate(page)
        var sorted = page
        sorted.elements.sort(by: Element.isOrderedBefore)
        return sorted
    }

    public static func decodeNotebook(_ data: Data) throws -> Notebook {
        try checkVersion(data, supported: Notebook.currentSchemaVersion)
        do {
            return try makeDecoder().decode(Notebook.self, from: data)
        } catch {
            throw CodecError.malformed(String(describing: error))
        }
    }

    public static func encodePage(_ page: Page) throws -> Data {
        let encoder = makeEncoder()
        func value<Value: Encodable>(_ value: Value) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var lines: [String] = []
        lines.append("{")
        if let color = page.color {
            lines.append("  \"color\": \(try value(color)),")
        }
        lines.append("  \"deleted\": \(try value(page.deleted)),")
        lines.append("  \"device\": \(try value(page.device)),")
        lines.append("  \"extent\": \(try value(page.extent)),")
        if let icon = page.icon {
            lines.append("  \"icon\": \(try value(icon)),")
        }
        lines.append("  \"id\": \(try value(page.id)),")
        lines.append("  \"notebook\": \(try value(page.notebook)),")
        if let order = page.order {
            lines.append("  \"order\": \(try value(order)),")
        }
        lines.append("  \"schema_version\": \(try value(page.schemaVersion)),")
        if let title = page.title {
            lines.append("  \"title\": \(try value(title)),")
        }
        lines.append("  \"updated\": \(try value(Timestamp.format(page.updated))),")
        let elements = page.elements.sorted(by: Element.isOrderedBefore)
        if elements.isEmpty {
            lines.append("  \"elements\": []")
        } else {
            lines.append("  \"elements\": [")
            let encodedElements = try elements.map { "    " + (try value($0)) }
            lines.append(encodedElements.joined(separator: ",\n"))
            lines.append("  ]")
        }
        lines.append("}")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func encodeNotebook(_ notebook: Notebook) throws -> Data {
        let encoder = makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        var data = try encoder.encode(notebook)
        data.append(Data("\n".utf8))
        return data
    }

    public static func validate(_ page: Page) throws {
        guard Identifier.hasPrefix(Identifier.pagePrefix, page.id) else {
            throw CodecError.invalid("page id \(page.id)")
        }
        guard page.extent.columns >= 1, page.extent.rows >= 1 else {
            throw CodecError.invalid("extent \(page.extent.columns)x\(page.extent.rows)")
        }
        var seen = Set<String>()
        for element in page.elements {
            guard seen.insert(element.id).inserted else {
                throw CodecError.invalid("duplicate element id \(element.id)")
            }
            switch element.type {
            case .stroke:
                guard element.layer == .ink || element.layer == .marker else {
                    throw CodecError.invalid("stroke \(element.id) on layer \(element.layer.rawValue)")
                }
                guard element.deleted || !(element.points ?? []).isEmpty else {
                    throw CodecError.invalid("stroke \(element.id) has no points")
                }
            case .text:
                guard element.layer == .text else {
                    throw CodecError.invalid("text \(element.id) on layer \(element.layer.rawValue)")
                }
            case .importPage:
                guard element.layer == .importLayer else {
                    throw CodecError.invalid("import \(element.id) on layer \(element.layer.rawValue)")
                }
            }
        }
    }

    static func checkVersion(_ data: Data, supported: Int) throws {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw CodecError.malformed(String(describing: error))
        }
        guard let version = probe.schemaVersion else {
            throw CodecError.malformed("missing schema_version")
        }
        guard version == supported else {
            throw CodecError.unsupportedSchemaVersion(version)
        }
    }
}
