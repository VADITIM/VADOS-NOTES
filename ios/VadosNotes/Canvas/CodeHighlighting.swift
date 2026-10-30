import NotesCore
import UIKit

enum CodeHighlighting {
    typealias LineToken = (range: NSRange, kind: SyntaxKind)

    private static func colors(_ style: PaperStyle) -> Tokens.SyntaxColorTokens {
        style == .light ? Tokens.shared.syntax.light : Tokens.shared.syntax.dark
    }

    static func background(_ style: PaperStyle) -> UIColor {
        UIColor(hex: colors(style).background)
    }

    static func color(_ kind: SyntaxKind, style: PaperStyle) -> UIColor {
        let palette = colors(style)
        switch kind {
        case .keyword: return UIColor(hex: palette.keyword)
        case .string: return UIColor(hex: palette.string)
        case .number: return UIColor(hex: palette.number)
        case .comment: return UIColor(hex: palette.comment)
        }
    }

    static func tokens(_ text: String, language: CodeLanguage) -> [LineToken] {
        SyntaxHighlighter.tokens(text, language: language).map { (NSRange($0.range, in: text), $0.kind) }
    }

    static func lineTokens(_ lines: [String], language: CodeLanguage) -> [[LineToken]] {
        let text = lines.joined(separator: "\n")
        var starts: [Int] = []
        var location = 0
        for line in lines {
            starts.append(location)
            location += line.utf16.count + 1
        }
        var result: [[LineToken]] = Array(repeating: [], count: lines.count)
        for token in tokens(text, language: language) {
            for (index, start) in starts.enumerated() {
                let lower = max(token.range.location, start)
                let upper = min(token.range.upperBound, start + lines[index].utf16.count)
                if upper > lower {
                    result[index].append((NSRange(location: lower - start, length: upper - lower), token.kind))
                }
            }
        }
        return result
    }

    static func colorize(_ text: NSMutableAttributedString, with tokens: [LineToken], at offset: Int, style: PaperStyle) {
        for token in tokens {
            let range = NSRange(location: offset + token.range.location, length: token.range.length)
            guard range.upperBound <= text.length else { continue }
            text.addAttribute(.foregroundColor, value: color(token.kind, style: style), range: range)
        }
    }
}
