import Foundation

public struct MarkdownStyle: Equatable, Hashable, Sendable {
    public var isBold = false
    public var isItalic = false
    public var isCode = false
    public var isStruck = false
    public var isLink = false

    public init(isBold: Bool = false, isItalic: Bool = false, isCode: Bool = false, isStruck: Bool = false, isLink: Bool = false) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isCode = isCode
        self.isStruck = isStruck
        self.isLink = isLink
    }
}

public struct MarkdownRun: Equatable, Sendable {
    public var text: String
    public var style: MarkdownStyle

    public init(text: String, style: MarkdownStyle) {
        self.text = text
        self.style = style
    }
}

public enum MarkdownBlockKind: String, Equatable, Sendable {
    case paragraph
    case heading
    case bullet
    case task
    case numbered
    case quote
    case rule
    case code
}

public struct MarkdownBlock: Equatable, Sendable {
    public var kind: MarkdownBlockKind
    public var scale: Double
    public var indent: Int
    public var marker: String?
    public var isChecked: Bool
    public var runs: [MarkdownRun]
}

public enum Markdown {
    public static let headingScales = [1.6, 1.35, 1.15]
    private static let indentPerLevel = 2

    private enum Emphasis: CaseIterable {
        case strongStars
        case strongUnderscores
        case strike
        case star
        case underscore

        var marker: [Character] {
            switch self {
            case .strongStars: return ["*", "*"]
            case .strongUnderscores: return ["_", "_"]
            case .strike: return ["~", "~"]
            case .star: return ["*"]
            case .underscore: return ["_"]
            }
        }

        var flag: WritableKeyPath<MarkdownStyle, Bool> {
            switch self {
            case .strongStars, .strongUnderscores: return \.isBold
            case .strike: return \.isStruck
            case .star, .underscore: return \.isItalic
            }
        }
    }

    private static let escapable: Set<Character> = ["\\", "`", "*", "_", "~", "[", "]", "(", ")", "#", "+", "-", ".", "!", ">"]

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    private static func isSpace(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.isWhitespace
    }

    private static func append(_ text: String, _ style: MarkdownStyle, to runs: inout [MarkdownRun]) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.style == style {
            runs[runs.count - 1].text += text
        } else {
            runs.append(MarkdownRun(text: text, style: style))
        }
    }

    private static func starts(_ characters: [Character], at index: Int, with marker: [Character]) -> Bool {
        guard index + marker.count <= characters.count else { return false }
        return Array(characters[index..<(index + marker.count)]) == marker
    }

    private static func contains(_ characters: [Character], _ marker: [Character], from index: Int) -> Bool {
        guard index < characters.count else { return false }
        var position = index
        while position + marker.count <= characters.count {
            if starts(characters, at: position, with: marker) {
                return true
            }
            position += 1
        }
        return false
    }

    private static func link(in characters: [Character], at index: Int) -> (label: String, length: Int)? {
        guard characters[index] == "[", let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 else { return nil }
        let open = close + 1
        guard open < characters.count, characters[open] == "(", let end = characters[(open + 1)...].firstIndex(of: ")"), end > open + 1 else { return nil }
        let target = characters[(open + 1)..<end]
        guard !target.contains(where: { $0.isWhitespace }) else { return nil }
        return (String(characters[(index + 1)..<close]), end - index + 1)
    }

    public static func runs(_ text: String, base: MarkdownStyle = MarkdownStyle()) -> [MarkdownRun] {
        let characters = Array(text)
        var runs: [MarkdownRun] = []
        var style = base
        var closers: [WritableKeyPath<MarkdownStyle, Bool>: [Character]] = [:]
        var buffer = ""
        var index = 0
        func flush() {
            append(buffer, style, to: &runs)
            buffer = ""
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, escapable.contains(characters[index + 1]) {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`", let closing = characters[(index + 1)...].firstIndex(of: "`"), closing > index + 1 {
                flush()
                var code = style
                code.isCode = true
                append(String(characters[(index + 1)..<closing]), code, to: &runs)
                index = closing + 1
                continue
            }
            if character == "[", let found = link(in: characters, at: index) {
                flush()
                var linked = style
                linked.isLink = true
                for run in self.runs(found.label, base: linked) {
                    append(run.text, run.style, to: &runs)
                }
                index += found.length
                continue
            }
            if let emphasis = Emphasis.allCases.first(where: { starts(characters, at: index, with: $0.marker) }) {
                let marker = emphasis.marker
                let flag = emphasis.flag
                let before: Character? = index > 0 ? characters[index - 1] : nil
                let after: Character? = index + marker.count < characters.count ? characters[index + marker.count] : nil
                let isUnderscore = marker[0] == "_"
                if style[keyPath: flag], closers[flag] == marker, !isSpace(before), !(isUnderscore && isWordCharacter(after)) {
                    flush()
                    style[keyPath: flag] = false
                    closers[flag] = nil
                    index += marker.count
                    continue
                }
                if !style[keyPath: flag], contains(characters, marker, from: index + marker.count), !isSpace(after), !(isUnderscore && isWordCharacter(before)) {
                    flush()
                    style[keyPath: flag] = true
                    closers[flag] = marker
                    index += marker.count
                    continue
                }
            }
            buffer.append(character)
            index += 1
        }
        flush()
        return runs
    }

    private static func leadingSpaces(_ line: [Character]) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func headingLevel(_ line: [Character]) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), hashes < line.count, line[hashes].isWhitespace else { return nil }
        return hashes
    }

    private static func isRule(_ line: [Character]) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listMarker(_ line: [Character], from start: Int) -> Int? {
        guard start + 1 < line.count, "-*+".contains(line[start]), line[start + 1].isWhitespace else { return nil }
        return start + 1
    }

    private static func trimmedStart(_ line: [Character], from index: Int) -> String {
        var position = index
        while position < line.count, line[position].isWhitespace {
            position += 1
        }
        return String(line[position...])
    }

    public static func blocks(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var isInFence = false
        for text in content.components(separatedBy: "\n") {
            let line = Array(text)
            let indent = leadingSpaces(line)
            let level = indent / indentPerLevel + 1
            if String(line[indent...]).hasPrefix("```") {
                isInFence.toggle()
                continue
            }
            if isInFence {
                blocks.append(MarkdownBlock(kind: .code, scale: 1, indent: 0, marker: nil, isChecked: false, runs: [MarkdownRun(text: text, style: MarkdownStyle(isCode: true))]))
                continue
            }
            if let hashes = headingLevel(line) {
                let scale = headingScales[min(hashes, headingScales.count) - 1]
                blocks.append(MarkdownBlock(kind: .heading, scale: scale, indent: 0, marker: nil, isChecked: false, runs: runs(trimmedStart(line, from: hashes), base: MarkdownStyle(isBold: true))))
                continue
            }
            if isRule(line) {
                blocks.append(MarkdownBlock(kind: .rule, scale: 1, indent: 0, marker: nil, isChecked: false, runs: []))
                continue
            }
            if let afterMarker = listMarker(line, from: indent) {
                let rest = Array(trimmedStart(line, from: afterMarker))
                if rest.count >= 3, rest[0] == "[", rest[2] == "]", " xX".contains(rest[1]), rest.count == 3 || rest[3].isWhitespace {
                    let isChecked = rest[1] != " "
                    blocks.append(MarkdownBlock(kind: .task, scale: 1, indent: level, marker: isChecked ? "☑" : "☐", isChecked: isChecked, runs: runs(trimmedStart(rest, from: 3))))
                } else {
                    blocks.append(MarkdownBlock(kind: .bullet, scale: 1, indent: level, marker: "•", isChecked: false, runs: runs(String(rest))))
                }
                continue
            }
            let digits = line[indent...].prefix { $0.isNumber }.count
            let separator = indent + digits
            if digits > 0, separator + 1 < line.count, ".)".contains(line[separator]), line[separator + 1].isWhitespace {
                blocks.append(MarkdownBlock(kind: .numbered, scale: 1, indent: level, marker: String(line[indent...separator]), isChecked: false, runs: runs(trimmedStart(line, from: separator + 1))))
                continue
            }
            if line.first == ">" {
                let rest = line.count > 1 && line[1] == " " ? String(line[2...]) : String(line[1...])
                blocks.append(MarkdownBlock(kind: .quote, scale: 1, indent: 1, marker: nil, isChecked: false, runs: runs(rest, base: MarkdownStyle(isItalic: true))))
                continue
            }
            blocks.append(MarkdownBlock(kind: .paragraph, scale: 1, indent: 0, marker: nil, isChecked: false, runs: runs(text)))
        }
        return blocks
    }
}
