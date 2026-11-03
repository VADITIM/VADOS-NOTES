export const codeLanguages = ["javascript", "csharp", "java", "python"]

export const languageTitles = { javascript: "JavaScript", csharp: "C#", java: "Java", python: "Python" }

export const languageCaptions = { javascript: "JS", csharp: "C#", java: "JAVA", python: "PY" }

export function codeLanguage(identifier) {
    switch (String(identifier ?? "").trim().toLowerCase()) {
    case "javascript": case "js": case "jsx": case "mjs": return "javascript"
    case "csharp": case "cs": case "c#": return "csharp"
    case "java": return "java"
    case "python": case "py": return "python"
    default: return null
    }
}

const grammars = {
    javascript: {
        keywords: new Set(["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield"]),
        lineComment: "//",
        blockComment: ["/*", "*/"],
        quotes: ["`", "\"", "'"],
        multilineQuotes: new Set(["`"]),
        identifierExtras: new Set(["$", "_"]),
    },
    csharp: {
        keywords: new Set(["abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char", "class", "const", "continue", "decimal", "default", "do", "double", "else", "enum", "false", "finally", "float", "for", "foreach", "get", "if", "in", "int", "interface", "internal", "is", "long", "namespace", "new", "null", "object", "out", "override", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "set", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "using", "var", "virtual", "void", "while", "yield"]),
        lineComment: "//",
        blockComment: ["/*", "*/"],
        quotes: ["\"\"\"", "\"", "'"],
        multilineQuotes: new Set(["\"\"\""]),
        identifierExtras: new Set(["_", "@"]),
    },
    java: {
        keywords: new Set(["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "null", "package", "private", "protected", "public", "record", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "true", "try", "var", "void", "volatile", "while"]),
        lineComment: "//",
        blockComment: ["/*", "*/"],
        quotes: ["\"\"\"", "\"", "'"],
        multilineQuotes: new Set(["\"\"\""]),
        identifierExtras: new Set(["_", "$"]),
    },
    python: {
        keywords: new Set(["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try", "while", "with", "yield"]),
        lineComment: "#",
        blockComment: null,
        quotes: ["\"\"\"", "'''", "\"", "'"],
        multilineQuotes: new Set(["\"\"\"", "'''"]),
        identifierExtras: new Set(["_"]),
    },
}

function isLetterOrNumber(character) {
    return /[\p{L}\p{N}]/u.test(character ?? "")
}

function isNumber(character) {
    return /\p{N}/u.test(character ?? "")
}

export function syntaxTokens(text, language) {
    const rules = grammars[language]
    if (!rules) {
        return []
    }
    const tokens = []
    const length = text.length
    let position = 0
    const starts = (marker, index) => text.startsWith(marker, index)
    const add = (start, end, kind) => {
        if (end > start) {
            tokens.push({ start, end, kind })
        }
    }
    const isIdentifier = (character) => isLetterOrNumber(character) || rules.identifierExtras.has(character)
    while (position < length) {
        const character = text[position]
        if (starts(rules.lineComment, position)) {
            let end = position
            while (end < length && text[end] !== "\n") {
                end += 1
            }
            add(position, end, "comment")
            position = end
            continue
        }
        if (rules.blockComment && starts(rules.blockComment[0], position)) {
            let end = position + rules.blockComment[0].length
            while (end < length && !starts(rules.blockComment[1], end)) {
                end += 1
            }
            end = Math.min(length, end + rules.blockComment[1].length)
            add(position, end, "comment")
            position = end
            continue
        }
        const quote = rules.quotes.find((candidate) => starts(candidate, position))
        if (quote) {
            const isMultiline = rules.multilineQuotes.has(quote)
            let end = position + quote.length
            while (end < length && !starts(quote, end)) {
                if (text[end] === "\\") {
                    end += 1
                } else if (text[end] === "\n" && !isMultiline) {
                    break
                }
                end += 1
            }
            end = Math.min(length, end + (starts(quote, end) ? quote.length : 0))
            add(position, end, "string")
            position = end
            continue
        }
        const isFraction = character === "." && isNumber(text[position + 1])
        if (isNumber(character) || isFraction) {
            const isAfterIdentifier = position > 0 && isIdentifier(text[position - 1])
            let end = position + 1
            while (end < length && (isLetterOrNumber(text[end]) || text[end] === "." || text[end] === "_")) {
                end += 1
            }
            if (!isAfterIdentifier) {
                add(position, end, "number")
            }
            position = end
            continue
        }
        if (isIdentifier(character)) {
            let end = position + 1
            while (end < length && isIdentifier(text[end])) {
                end += 1
            }
            if (rules.keywords.has(text.slice(position, end))) {
                add(position, end, "keyword")
            }
            position = end
            continue
        }
        position += 1
    }
    return tokens
}

export function lineSyntaxTokens(lines, language) {
    const text = lines.join("\n")
    const starts = []
    let location = 0
    for (const line of lines) {
        starts.push(location)
        location += line.length + 1
    }
    const result = lines.map(() => [])
    for (const token of syntaxTokens(text, language)) {
        starts.forEach((start, index) => {
            const lower = Math.max(token.start, start)
            const upper = Math.min(token.end, start + lines[index].length)
            if (upper > lower) {
                result[index].push({ start: lower - start, end: upper - start, kind: token.kind })
            }
        })
    }
    return result
}
