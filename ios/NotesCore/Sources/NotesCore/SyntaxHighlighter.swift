import Foundation

public enum CodeLanguage: String, CaseIterable, Sendable {
    case javascript
    case csharp
    case java
    case python

    public var title: String {
        switch self {
        case .javascript: return "JavaScript"
        case .csharp: return "C#"
        case .java: return "Java"
        case .python: return "Python"
        }
    }

    public init?(identifier: String) {
        switch identifier.trimmingCharacters(in: .whitespaces).lowercased() {
        case "javascript", "js", "jsx", "mjs": self = .javascript
        case "csharp", "cs", "c#": self = .csharp
        case "java": self = .java
        case "python", "py": self = .python
        default: return nil
        }
    }
}

public enum SyntaxKind: String, Equatable, Sendable {
    case keyword
    case string
    case number
    case comment
}

public struct SyntaxToken: Equatable, Sendable {
    public var range: Range<String.Index>
    public var kind: SyntaxKind
}

public enum SyntaxHighlighter {
    private struct Grammar {
        let keywords: Set<String>
        let lineComment: String
        let blockComment: (open: String, close: String)?
        let quotes: [String]
        let multilineQuotes: Set<String>
        let identifierExtras: Set<Character>
    }

    private static let javascript = Grammar(
        keywords: ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield"],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        quotes: ["`", "\"", "'"],
        multilineQuotes: ["`"],
        identifierExtras: ["$", "_"]
    )

    private static let csharp = Grammar(
        keywords: ["abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char", "class", "const", "continue", "decimal", "default", "do", "double", "else", "enum", "false", "finally", "float", "for", "foreach", "get", "if", "in", "int", "interface", "internal", "is", "long", "namespace", "new", "null", "object", "out", "override", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "set", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "using", "var", "virtual", "void", "while", "yield"],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        quotes: ["\"\"\"", "\"", "'"],
        multilineQuotes: ["\"\"\""],
        identifierExtras: ["_", "@"]
    )

    private static let java = Grammar(
        keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "null", "package", "private", "protected", "public", "record", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "true", "try", "var", "void", "volatile", "while"],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        quotes: ["\"\"\"", "\"", "'"],
        multilineQuotes: ["\"\"\""],
        identifierExtras: ["_", "$"]
    )

    private static let python = Grammar(
        keywords: ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try", "while", "with", "yield"],
        lineComment: "#",
        blockComment: nil,
        quotes: ["\"\"\"", "'''", "\"", "'"],
        multilineQuotes: ["\"\"\"", "'''"],
        identifierExtras: ["_"]
    )

    private static func grammar(_ language: CodeLanguage) -> Grammar {
        switch language {
        case .javascript: return javascript
        case .csharp: return csharp
        case .java: return java
        case .python: return python
        }
    }

    public static func tokens(_ text: String, language: CodeLanguage) -> [SyntaxToken] {
        let rules = grammar(language)
        let characters = Array(text)
        var indices = Array(text.indices)
        indices.append(text.endIndex)
        var tokens: [SyntaxToken] = []
        var position = 0

        func starts(_ marker: String, at index: Int) -> Bool {
            let marker = Array(marker)
            guard index + marker.count <= characters.count else { return false }
            return Array(characters[index..<(index + marker.count)]) == marker
        }

        func add(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            guard end > start else { return }
            tokens.append(SyntaxToken(range: indices[start]..<indices[end], kind: kind))
        }

        func isIdentifier(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || rules.identifierExtras.contains(character)
        }

        while position < characters.count {
            let character = characters[position]
            if starts(rules.lineComment, at: position) {
                var end = position
                while end < characters.count, characters[end] != "\n" {
                    end += 1
                }
                add(position, end, .comment)
                position = end
                continue
            }
            if let block = rules.blockComment, starts(block.open, at: position) {
                var end = position + block.open.count
                while end < characters.count, !starts(block.close, at: end) {
                    end += 1
                }
                end = min(characters.count, end + block.close.count)
                add(position, end, .comment)
                position = end
                continue
            }
            if let quote = rules.quotes.first(where: { starts($0, at: position) }) {
                let isMultiline = rules.multilineQuotes.contains(quote)
                var end = position + quote.count
                while end < characters.count, !starts(quote, at: end) {
                    if characters[end] == "\\" {
                        end += 1
                    } else if characters[end] == "\n", !isMultiline {
                        break
                    }
                    end += 1
                }
                end = min(characters.count, end + (starts(quote, at: end) ? quote.count : 0))
                add(position, end, .string)
                position = end
                continue
            }
            let isFraction = character == "." && position + 1 < characters.count && characters[position + 1].isNumber
            if character.isNumber || isFraction {
                let isAfterIdentifier = position > 0 && isIdentifier(characters[position - 1])
                var end = position + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "." || characters[end] == "_" {
                    end += 1
                }
                if !isAfterIdentifier {
                    add(position, end, .number)
                }
                position = end
                continue
            }
            if isIdentifier(character) {
                var end = position + 1
                while end < characters.count, isIdentifier(characters[end]) {
                    end += 1
                }
                if rules.keywords.contains(String(characters[position..<end])) {
                    add(position, end, .keyword)
                }
                position = end
                continue
            }
            position += 1
        }
        return tokens
    }
}
