import Foundation

public struct CodeEdit: Equatable, Sendable {
    public var replacement: String
    public var removedBefore: Int
    public var removedAfter: Int
    public var caret: Int

    public init(replacement: String, removedBefore: Int = 0, removedAfter: Int = 0, caret: Int? = nil) {
        self.replacement = replacement
        self.removedBefore = removedBefore
        self.removedAfter = removedAfter
        self.caret = caret ?? replacement.utf16.count
    }
}

public enum CodeIndentation {
    public static let defaultUnit = 4
    public static let closers: Set<Character> = ["}", ")", "]"]
    private static let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]"]
    private static let pythonExits: Set<String> = ["return", "pass", "break", "continue", "raise"]

    public static func unit(_ lines: [String]) -> Int {
        let widths = lines.compactMap { line -> Int? in
            guard line.contains(where: { !$0.isWhitespace }) else { return nil }
            let width = line.prefix(while: { $0 == " " }).count
            return width > 0 ? width : nil
        }
        guard let smallest = widths.min() else { return defaultUnit }
        return min(max(smallest, 2), 8)
    }

    public static func leading(_ line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    public static func newline(before: String, after: String, language: CodeLanguage?, unit: Int) -> CodeEdit {
        let indent = leading(before)
        let code = significant(before, language: language)
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        let opener = unclosedOpener(code)
        let rest = after.drop(while: { $0 == " " || $0 == "\t" })
        let consumed = after.utf16.count - String(rest).utf16.count
        let isOpening = opener != nil || (language == .python && trimmed.hasSuffix(":"))
        if isOpening {
            let inner = indent + String(repeating: " ", count: unit)
            if let opener, rest.first == pairs[opener] {
                return CodeEdit(replacement: "\n" + inner + "\n" + indent, removedAfter: consumed, caret: 1 + inner.utf16.count)
            }
            return CodeEdit(replacement: "\n" + inner, removedAfter: consumed)
        }
        let firstWord = String(trimmed.prefix(while: { $0.isLetter }))
        if language == .python, pythonExits.contains(firstWord) {
            return CodeEdit(replacement: "\n" + dedented(indent, unit: unit), removedAfter: consumed)
        }
        return CodeEdit(replacement: "\n" + indent, removedAfter: consumed)
    }

    public static func closing(before: String, character: Character, unit: Int) -> CodeEdit? {
        guard closers.contains(character), !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return CodeEdit(replacement: dedented(before, unit: unit) + String(character), removedBefore: before.utf16.count)
    }

    public static func opening(after: String, character: Character) -> CodeEdit? {
        guard let closer = pairs[character] else { return nil }
        if let next = after.first, !next.isWhitespace, !closers.contains(next) {
            return nil
        }
        return CodeEdit(replacement: String(character) + String(closer), caret: 1)
    }

    public static func overtype(after: String, character: Character) -> CodeEdit? {
        guard closers.contains(character), after.first == character else { return nil }
        return CodeEdit(replacement: String(character), removedAfter: 1)
    }

    public static func pairBackspace(before: String, after: String) -> CodeEdit? {
        guard let opener = before.last, let closer = pairs[opener], after.first == closer else { return nil }
        return CodeEdit(replacement: "", removedBefore: 1, removedAfter: 1)
    }

    public static func backspace(before: String, unit: Int) -> CodeEdit? {
        guard !before.isEmpty, before.allSatisfy({ $0 == " " }) else { return nil }
        let target = ((before.count - 1) / unit) * unit
        return CodeEdit(replacement: "", removedBefore: before.count - target)
    }

    public static func tab(before: String, unit: Int) -> CodeEdit {
        CodeEdit(replacement: String(repeating: " ", count: unit - before.count % unit))
    }

    public static func dedented(_ indent: String, unit: Int) -> String {
        if indent.hasSuffix("\t") {
            return String(indent.dropLast())
        }
        let spaces = indent.reversed().prefix(while: { $0 == " " }).count
        guard spaces > 0 else { return indent }
        let target = ((spaces - 1) / unit) * unit
        return String(indent.dropLast(spaces - target))
    }

    private static func significant(_ text: String, language: CodeLanguage?) -> String {
        guard let language else { return text }
        var result = ""
        var position = text.startIndex
        for token in SyntaxHighlighter.tokens(text, language: language) where token.kind == .string || token.kind == .comment {
            result += text[position..<token.range.lowerBound]
            position = token.range.upperBound
        }
        result += text[position...]
        return result
    }

    private static func unclosedOpener(_ code: String) -> Character? {
        var stack: [Character] = []
        for character in code {
            if pairs[character] != nil {
                stack.append(character)
            } else if closers.contains(character), let last = stack.last, pairs[last] == character {
                stack.removeLast()
            }
        }
        return stack.last
    }
}
