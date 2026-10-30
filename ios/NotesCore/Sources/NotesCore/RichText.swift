import Foundation

public struct RichLineShape: Equatable, Sendable {
    public var kind: MarkdownBlockKind
    public var prefixLength: Int
    public var headingLevel: Int

    public init(kind: MarkdownBlockKind, prefixLength: Int, headingLevel: Int) {
        self.kind = kind
        self.prefixLength = prefixLength
        self.headingLevel = headingLevel
    }

    public var isVerbatim: Bool {
        kind == .code || kind == .rule
    }

    public var scale: Double {
        guard kind == .heading else { return 1 }
        return Markdown.headingScales[min(headingLevel, Markdown.headingScales.count) - 1]
    }
}

public enum RichText {
    private enum Mark: Equatable {
        case link(String)
        case underline
        case dashedUnderline
        case strike
        case bold
        case italic

        var opening: String {
            switch self {
            case .link: return "["
            case .underline: return Markdown.underlineTag
            case .dashedUnderline: return Markdown.dashedUnderlineTag
            case .strike: return "~~"
            case .bold: return "**"
            case .italic: return "*"
            }
        }

        var closing: String {
            switch self {
            case .link(let target): return "](\(target))"
            case .underline, .dashedUnderline: return Markdown.underlineCloseTag
            case .strike: return "~~"
            case .bold: return "**"
            case .italic: return "*"
            }
        }
    }

    private static let trimmedMarks: [(flag: WritableKeyPath<MarkdownStyle, Bool>, mark: Mark)] = [(\.isStruck, .strike), (\.isBold, .bold), (\.isItalic, .italic)]
    private static let fullEscapes: Set<Character> = ["\\", "`", "*", "_", "~", "[", "<"]

    public static func shapes(_ lines: [String]) -> [RichLineShape] {
        var isInFence = false
        return lines.map { text in
            let line = Array(text)
            let indent = Markdown.leadingSpaces(line)
            if String(line[indent...]).hasPrefix("```") {
                isInFence.toggle()
                return RichLineShape(kind: .code, prefixLength: line.count, headingLevel: 0)
            }
            if isInFence {
                return RichLineShape(kind: .code, prefixLength: line.count, headingLevel: 0)
            }
            if let hashes = Markdown.headingLevel(line) {
                return RichLineShape(kind: .heading, prefixLength: skippingSpaces(line, from: hashes), headingLevel: hashes)
            }
            if Markdown.isRule(line) {
                return RichLineShape(kind: .rule, prefixLength: line.count, headingLevel: 0)
            }
            if let afterMarker = Markdown.listMarker(line, from: indent) {
                let start = skippingSpaces(line, from: afterMarker)
                let rest = Array(line[start...])
                if rest.count >= 3, rest[0] == "[", rest[2] == "]", " xX".contains(rest[1]), rest.count == 3 || rest[3].isWhitespace {
                    return RichLineShape(kind: .task, prefixLength: skippingSpaces(line, from: start + 3), headingLevel: 0)
                }
                return RichLineShape(kind: .bullet, prefixLength: start, headingLevel: 0)
            }
            let digits = line[indent...].prefix { $0.isNumber }.count
            let separator = indent + digits
            if digits > 0, separator + 1 < line.count, ".)".contains(line[separator]), line[separator + 1].isWhitespace {
                return RichLineShape(kind: .numbered, prefixLength: skippingSpaces(line, from: separator + 1), headingLevel: 0)
            }
            if line.first == ">" {
                return RichLineShape(kind: .quote, prefixLength: line.count > 1 && line[1] == " " ? 2 : 1, headingLevel: 0)
            }
            return RichLineShape(kind: .paragraph, prefixLength: 0, headingLevel: 0)
        }
    }

    public static func lines(_ markdown: String) -> [[MarkdownRun]] {
        let texts = markdown.components(separatedBy: "\n")
        return zip(texts, shapes(texts)).map { text, shape in
            let characters = Array(text)
            guard !shape.isVerbatim else {
                return text.isEmpty ? [] : [MarkdownRun(text: text, style: MarkdownStyle())]
            }
            var runs: [MarkdownRun] = []
            append(String(characters[..<shape.prefixLength]), MarkdownStyle(), to: &runs)
            for run in Markdown.runs(String(characters[shape.prefixLength...])) {
                append(run.text, run.style, to: &runs)
            }
            return runs
        }
    }

    public static func markdown(_ lines: [[MarkdownRun]]) -> String {
        let texts = lines.map { $0.map(\.text).joined() }
        return zip(zip(lines, texts), shapes(texts)).map { line, shape in
            let (runs, text) = line
            guard !shape.isVerbatim else { return text }
            let prefix = String(Array(text)[..<shape.prefixLength])
            return prefix + inline(dropping(shape.prefixLength, from: runs))
        }
        .joined(separator: "\n")
    }

    public static func inline(_ runs: [MarkdownRun]) -> String {
        let normal = normalized(runs)
        let minimal = serialized(normal, escapes: [])
        if Markdown.runs(minimal) == normal {
            return minimal
        }
        return serialized(normal, escapes: fullEscapes)
    }

    public static func normalized(_ runs: [MarkdownRun]) -> [MarkdownRun] {
        var characters: [(character: Character, style: MarkdownStyle)] = runs.flatMap { run in
            run.text.map { (character: $0, style: run.style) }
        }
        for index in characters.indices {
            if !characters[index].style.isLink || characters[index].style.linkTarget == nil {
                characters[index].style.isLink = false
                characters[index].style.linkTarget = nil
            }
            if characters[index].style.isDashedUnderlined {
                characters[index].style.isUnderlined = false
            }
        }
        for (flag, mark) in trimmedMarks {
            func outerMarks(_ index: Int) -> [Mark]? {
                let present = marks(characters[index].style)
                return present.firstIndex(of: mark).map { Array(present[..<$0]) }
            }
            var start = 0
            while start < characters.count {
                guard let outer = outerMarks(start) else {
                    start += 1
                    continue
                }
                var end = start
                while end < characters.count, outerMarks(end) == outer {
                    end += 1
                }
                var low = start
                while low < end, characters[low].character.isWhitespace {
                    characters[low].style[keyPath: flag] = false
                    low += 1
                }
                var high = end - 1
                while high >= low, characters[high].character.isWhitespace {
                    characters[high].style[keyPath: flag] = false
                    high -= 1
                }
                start = end
            }
        }
        var result: [MarkdownRun] = []
        for item in characters {
            append(String(item.character), item.style, to: &result)
        }
        return result
    }

    private static func marks(_ style: MarkdownStyle) -> [Mark] {
        var marks: [Mark] = []
        if style.isLink, let target = style.linkTarget {
            marks.append(.link(target))
        }
        if style.isDashedUnderlined {
            marks.append(.dashedUnderline)
        } else if style.isUnderlined {
            marks.append(.underline)
        }
        if style.isStruck {
            marks.append(.strike)
        }
        if style.isBold {
            marks.append(.bold)
        }
        if style.isItalic {
            marks.append(.italic)
        }
        return marks
    }

    private static func serialized(_ runs: [MarkdownRun], escapes: Set<Character>) -> String {
        var output = ""
        var open: [Mark] = []
        for run in runs {
            let wanted = marks(run.style)
            let kept = zip(open, wanted).prefix { $0 == $1 }.count
            for mark in open[kept...].reversed() {
                output += mark.closing
            }
            for mark in wanted[kept...] {
                output += mark.opening
            }
            open = wanted
            output += run.style.isCode ? code(run.text) : escaped(run.text, escapes)
        }
        for mark in open.reversed() {
            output += mark.closing
        }
        return output
    }

    private static func code(_ text: String) -> String {
        text.components(separatedBy: "`").map { $0.isEmpty ? "" : "`\($0)`" }.joined(separator: "\\`")
    }

    private static func escaped(_ text: String, _ escapes: Set<Character>) -> String {
        let characters = Array(text)
        var output = ""
        for (index, character) in characters.enumerated() {
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "\\" {
                if escapes.contains(character) || next.map({ Markdown.escapable.contains($0) }) ?? true {
                    output.append("\\")
                }
            } else if escapes.contains(character) {
                output.append("\\")
            }
            output.append(character)
        }
        return output
    }

    private static func dropping(_ count: Int, from runs: [MarkdownRun]) -> [MarkdownRun] {
        var remaining = count
        var result: [MarkdownRun] = []
        for run in runs {
            let length = run.text.count
            if remaining >= length {
                remaining -= length
                continue
            }
            result.append(MarkdownRun(text: String(run.text.dropFirst(remaining)), style: run.style))
            remaining = 0
        }
        return result
    }

    private static func skippingSpaces(_ line: [Character], from index: Int) -> Int {
        var position = index
        while position < line.count, line[position].isWhitespace {
            position += 1
        }
        return position
    }

    private static func append(_ text: String, _ style: MarkdownStyle, to runs: inout [MarkdownRun]) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.style == style {
            runs[runs.count - 1].text += text
        } else {
            runs.append(MarkdownRun(text: text, style: style))
        }
    }
}
