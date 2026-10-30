import NotesCore
import SwiftUI
import UIKit

struct TextStyleState: Equatable {
    var style = MarkdownStyle()
    var lineKind: MarkdownBlockKind = .paragraph
    var codeLanguage: CodeLanguage?

    var isPlainText: Bool {
        !style.isCode && lineKind != .code
    }
}

enum TextStyleCommand: Equatable {
    case inline(WritableKeyPath<MarkdownStyle, Bool>)
    case line(MarkdownBlockKind)
    case code(CodeLanguage?)
}

struct TextStyleRequest: Equatable {
    let serial: Int
    let command: TextStyleCommand
}

final class MarkdownStyleValue: NSObject {
    let style: MarkdownStyle

    init(_ style: MarkdownStyle) {
        self.style = style
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? MarkdownStyleValue)?.style == style
    }

    override var hash: Int {
        style.hashValue
    }
}

extension NSAttributedString.Key {
    static let markdownStyle = NSAttributedString.Key("VadosNotesMarkdownStyle")
}

struct TextBlockEditor: UIViewRepresentable {
    let text: String
    let zoom: CGFloat
    let color: UIColor
    let paperStyle: PaperStyle
    let styleRequest: TextStyleRequest?
    let onChange: (String) -> Void
    let onStyleState: (TextStyleState) -> Void

    private static let inlineFlags: [WritableKeyPath<MarkdownStyle, Bool>] = [\.isBold, \.isItalic, \.isStruck, \.isUnderlined, \.isDashedUnderlined, \.isCode]
    private static let prefixShade: CGFloat = 0.45

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void
        var onStyleState: (TextStyleState) -> Void
        var styleSerial = 0
        var markdown = ""
        var zoom: CGFloat = 1
        var color: UIColor = .white
        var paperStyle: PaperStyle = .dark
        private var reported: TextStyleState?

        init(onChange: @escaping (String) -> Void, onStyleState: @escaping (TextStyleState) -> Void) {
            self.onChange = onChange
            self.onStyleState = onStyleState
        }

        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            commit(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            report(textView)
        }

        func load(_ markdown: String, into view: UITextView) {
            let plain = [NSAttributedString.Key.markdownStyle: MarkdownStyleValue(MarkdownStyle())]
            let result = NSMutableAttributedString()
            for (index, runs) in RichText.lines(markdown).enumerated() {
                if index > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: plain))
                }
                for run in runs {
                    result.append(NSAttributedString(string: run.text, attributes: [.markdownStyle: MarkdownStyleValue(run.style)]))
                }
            }
            let selection = view.selectedRange
            view.textStorage.setAttributedString(result)
            restyle(view)
            view.selectedRange = NSRange(location: min(selection.location, result.length), length: 0)
            refreshTypingAttributes(view)
            self.markdown = markdown
            report(view)
        }

        func restyle(_ view: UITextView) {
            let storage = view.textStorage
            let texts = storage.string.components(separatedBy: "\n")
            let shapes = RichText.shapes(texts)
            storage.beginEditing()
            var location = 0
            var codeLines: [(index: Int, location: Int, text: String, language: CodeLanguage)] = []
            for (index, (text, shape)) in zip(texts, shapes).enumerated() {
                let length = text.utf16.count
                let paragraph = NSRange(location: location, length: min(length + 1, storage.length - location))
                let isFence = shape.kind == .code && Self.isFence(text)
                if shape.kind == .code, !isFence, let language = shape.language {
                    codeLines.append((index, location, text, language))
                }
                let prefixEnd = shape.isVerbatim ? (isFence ? location + length : location) : location + String(text.prefix(shape.prefixLength)).utf16.count
                var pieces: [(range: NSRange, style: MarkdownStyle)] = []
                storage.enumerateAttribute(.markdownStyle, in: paragraph) { value, range, _ in
                    let style = (value as? MarkdownStyleValue)?.style ?? MarkdownStyle()
                    if range.location < prefixEnd {
                        let inPrefix = NSRange(location: range.location, length: min(range.upperBound, prefixEnd) - range.location)
                        pieces.append((inPrefix, style))
                        if range.upperBound > prefixEnd {
                            pieces.append((NSRange(location: prefixEnd, length: range.upperBound - prefixEnd), style))
                        }
                    } else {
                        pieces.append((range, style))
                    }
                }
                for piece in pieces {
                    let isPrefix = piece.range.location < prefixEnd
                    storage.setAttributes(attributes(piece.style, shape: shape, isPrefix: isPrefix), range: piece.range)
                    if !isPrefix, !shape.isVerbatim, piece.style.isCode, let language = piece.style.codeLanguage {
                        let text = (storage.string as NSString).substring(with: piece.range)
                        CodeHighlighting.colorize(storage, with: CodeHighlighting.tokens(text, language: language), at: piece.range.location, style: paperStyle)
                    }
                }
                location += length + 1
            }
            var start = 0
            while start < codeLines.count {
                var end = start + 1
                while end < codeLines.count, codeLines[end].index == codeLines[end - 1].index + 1, codeLines[end].language == codeLines[start].language {
                    end += 1
                }
                let group = codeLines[start..<end]
                for (line, tokens) in zip(group, CodeHighlighting.lineTokens(group.map(\.text), language: codeLines[start].language)) {
                    CodeHighlighting.colorize(storage, with: tokens, at: line.location, style: paperStyle)
                }
                start = end
            }
            storage.endEditing()
        }

        static func isFence(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }

        func attributes(_ style: MarkdownStyle, shape: RichLineShape, isPrefix: Bool) -> [NSAttributedString.Key: Any] {
            var look = style
            if isPrefix {
                look = MarkdownStyle(isBold: shape.kind == .heading)
            } else if shape.isVerbatim {
                look = MarkdownStyle(isCode: shape.kind == .code)
            } else {
                look.isBold = look.isBold || shape.kind == .heading
                look.isItalic = look.isItalic || shape.kind == .quote
            }
            let isDimmed = isPrefix || shape.kind == .rule
            var attributes = MarkdownText.runAttributes(
                look,
                size: TextRhythm.fontSize * CGFloat(shape.scale),
                rows: TextRhythm.rows(for: shape.scale),
                zoom: zoom,
                color: isDimmed ? color.withAlphaComponent(TextBlockEditor.prefixShade) : color,
                paperStyle: paperStyle,
                isInCodeBlock: false
            )
            attributes[.markdownStyle] = MarkdownStyleValue(isPrefix || shape.isVerbatim ? MarkdownStyle() : style)
            return attributes
        }

        func commit(_ view: UITextView) {
            restyle(view)
            refreshTypingAttributes(view)
            report(view)
            let next = RichText.markdown(lines(of: view.textStorage))
            guard next != markdown else { return }
            markdown = next
            onChange(next)
        }

        private func lines(of storage: NSTextStorage) -> [[MarkdownRun]] {
            let string = storage.string as NSString
            var location = 0
            return storage.string.components(separatedBy: "\n").map { text in
                let range = NSRange(location: location, length: text.utf16.count)
                location += range.length + 1
                var runs: [MarkdownRun] = []
                storage.enumerateAttribute(.markdownStyle, in: range) { value, piece, _ in
                    runs.append(MarkdownRun(text: string.substring(with: piece), style: (value as? MarkdownStyleValue)?.style ?? MarkdownStyle()))
                }
                return runs
            }
        }

        private func lineShape(at location: Int, in view: UITextView) -> RichLineShape {
            let texts = view.textStorage.string.components(separatedBy: "\n")
            let shapes = RichText.shapes(texts)
            var start = 0
            for (text, shape) in zip(texts, shapes) {
                let end = start + text.utf16.count
                if location <= end {
                    return shape
                }
                start = end + 1
            }
            return shapes.last ?? RichLineShape(kind: .paragraph, prefixLength: 0, headingLevel: 0)
        }

        private func style(at location: Int, in storage: NSTextStorage) -> MarkdownStyle {
            guard location >= 0, location < storage.length else { return MarkdownStyle() }
            return (storage.attribute(.markdownStyle, at: location, effectiveRange: nil) as? MarkdownStyleValue)?.style ?? MarkdownStyle()
        }

        private func refreshTypingAttributes(_ view: UITextView) {
            let caret = view.selectedRange.location
            let storage = view.textStorage
            let string = storage.string as NSString
            let isLineStart = caret == 0 || string.character(at: caret - 1) == 10
            let typing = isLineStart ? MarkdownStyle() : style(at: caret - 1, in: storage)
            view.typingAttributes = attributes(typing, shape: lineShape(at: caret, in: view), isPrefix: false)
        }

        private func report(_ view: UITextView) {
            let range = view.selectedRange
            var state = TextStyleState()
            let shape = lineShape(at: range.location, in: view)
            state.lineKind = shape.kind
            if range.length > 0 {
                let string = view.textStorage.string as NSString
                var flags = Dictionary(uniqueKeysWithValues: TextBlockEditor.inlineFlags.map { ($0, true) })
                var languages: Set<CodeLanguage?> = []
                view.textStorage.enumerateAttribute(.markdownStyle, in: range) { value, piece, _ in
                    guard string.substring(with: piece).contains(where: { $0 != "\n" }) else { return }
                    let style = (value as? MarkdownStyleValue)?.style ?? MarkdownStyle()
                    languages.insert(style.codeLanguage)
                    for flag in TextBlockEditor.inlineFlags where !style[keyPath: flag] {
                        flags[flag] = false
                    }
                }
                for flag in TextBlockEditor.inlineFlags {
                    state.style[keyPath: flag] = flags[flag] ?? false
                }
                if state.style.isCode, languages.count == 1 {
                    state.codeLanguage = languages.first ?? nil
                }
            } else {
                state.style = (view.typingAttributes[.markdownStyle] as? MarkdownStyleValue)?.style ?? MarkdownStyle()
                state.codeLanguage = state.style.isCode ? state.style.codeLanguage : nil
            }
            if shape.kind == .code {
                state.codeLanguage = shape.language
            }
            guard state != reported else { return }
            reported = state
            let onStyleState = onStyleState
            DispatchQueue.main.async {
                onStyleState(state)
            }
        }

        func perform(_ command: TextStyleCommand, in view: UITextView) {
            switch command {
            case .inline(let flag):
                toggle(flag, in: view)
            case .line(let kind):
                setLines(kind, in: view)
            case .code(let language):
                setCode(language, in: view)
            }
        }

        private func lineStarts(_ texts: [String]) -> [Int] {
            var starts: [Int] = []
            var location = 0
            for text in texts {
                starts.append(location)
                location += text.utf16.count + 1
            }
            return starts
        }

        private func fencedBlocks(_ texts: [String]) -> [(open: Int, close: Int?)] {
            var blocks: [(open: Int, close: Int?)] = []
            var open: Int?
            for (index, text) in texts.enumerated() where Self.isFence(text) {
                if let start = open {
                    blocks.append((start, index))
                    open = nil
                } else {
                    open = index
                }
            }
            if let open {
                blocks.append((open, nil))
            }
            return blocks
        }

        private func coded(_ style: MarkdownStyle, _ language: CodeLanguage?) -> MarkdownStyle {
            var result = style
            result.isCode = language != nil
            result.codeLanguage = language
            return result
        }

        private func setCode(_ language: CodeLanguage?, in view: UITextView) {
            let storage = view.textStorage
            let string = storage.string as NSString
            let texts = storage.string.components(separatedBy: "\n")
            let starts = lineStarts(texts)
            let selection = view.selectedRange
            let touched = texts.indices.filter { index in
                starts[index] + texts[index].utf16.count >= selection.location && starts[index] <= selection.upperBound
            }
            let blocks = fencedBlocks(texts).filter { block in
                touched.contains { $0 >= block.open && $0 <= (block.close ?? texts.count - 1) }
            }
            if !blocks.isEmpty {
                var edits: [(range: NSRange, replacement: String)] = []
                for block in blocks {
                    if let language {
                        edits.append((NSRange(location: starts[block.open], length: texts[block.open].utf16.count), "```" + language.rawValue))
                        continue
                    }
                    for index in [block.open, block.close].compactMap({ $0 }) {
                        let isLast = index == texts.count - 1
                        let location = isLast && index > 0 ? starts[index] - 1 : starts[index]
                        edits.append((NSRange(location: location, length: min(texts[index].utf16.count + 1, storage.length - location)), ""))
                    }
                }
                replace(edits, in: view, keeping: selection)
                return
            }
            if selection.length > 0, string.substring(with: selection).contains("\n"), let language, let first = touched.first, let last = touched.last {
                let opening = "```" + language.rawValue + "\n"
                let lastEnd = starts[last] + texts[last].utf16.count
                replace([(NSRange(location: starts[first], length: 0), opening), (NSRange(location: lastEnd, length: 0), "\n```")], in: view, keeping: NSRange(location: starts[first], length: lastEnd - starts[first]))
                return
            }
            var target = selection
            if selection.length == 0 {
                let isInSpan = selection.location > 0 && style(at: selection.location - 1, in: storage).isCode
                guard isInSpan, let line = touched.first else {
                    let current = (view.typingAttributes[.markdownStyle] as? MarkdownStyleValue)?.style ?? MarkdownStyle()
                    view.typingAttributes = attributes(coded(current, language), shape: lineShape(at: selection.location, in: view), isPrefix: false)
                    report(view)
                    return
                }
                var span = NSRange()
                _ = storage.attribute(.markdownStyle, at: selection.location - 1, longestEffectiveRange: &span, in: NSRange(location: starts[line], length: texts[line].utf16.count))
                target = span
            }
            var pieces: [(range: NSRange, style: MarkdownStyle)] = []
            storage.enumerateAttribute(.markdownStyle, in: target) { value, piece, _ in
                guard string.substring(with: piece).contains(where: { $0 != "\n" }) else { return }
                pieces.append((piece, (value as? MarkdownStyleValue)?.style ?? MarkdownStyle()))
            }
            storage.beginEditing()
            for piece in pieces {
                storage.addAttribute(.markdownStyle, value: MarkdownStyleValue(coded(piece.style, language)), range: piece.range)
            }
            storage.endEditing()
            view.selectedRange = selection
            commit(view)
        }

        private func replace(_ edits: [(range: NSRange, replacement: String)], in view: UITextView, keeping selection: NSRange) {
            let storage = view.textStorage
            var start = selection.location
            var end = selection.upperBound
            for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
                let delta = edit.replacement.utf16.count - edit.range.length
                if edit.range.upperBound <= start {
                    start += delta
                } else if edit.range.location < start {
                    start = edit.range.location + edit.replacement.utf16.count
                }
                if edit.range.length == 0, edit.range.location == end, end > start {
                    continue
                }
                if edit.range.upperBound <= end {
                    end += delta
                } else if edit.range.location < end {
                    end = edit.range.location + edit.replacement.utf16.count
                }
            }
            storage.beginEditing()
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: [.markdownStyle: MarkdownStyleValue(MarkdownStyle())]))
            }
            storage.endEditing()
            let length = storage.length
            let location = min(max(0, start), length)
            view.selectedRange = NSRange(location: location, length: max(0, min(end, length) - location))
            commit(view)
        }

        private func toggled(_ style: MarkdownStyle, _ flag: WritableKeyPath<MarkdownStyle, Bool>, to isOn: Bool) -> MarkdownStyle {
            var result = style
            result[keyPath: flag] = isOn
            if isOn, flag == \MarkdownStyle.isUnderlined {
                result.isDashedUnderlined = false
            }
            if isOn, flag == \MarkdownStyle.isDashedUnderlined {
                result.isUnderlined = false
            }
            return result
        }

        private func toggle(_ flag: WritableKeyPath<MarkdownStyle, Bool>, in view: UITextView) {
            let range = view.selectedRange
            let storage = view.textStorage
            guard range.length > 0 else {
                let current = (view.typingAttributes[.markdownStyle] as? MarkdownStyleValue)?.style ?? MarkdownStyle()
                let shape = lineShape(at: range.location, in: view)
                view.typingAttributes = attributes(toggled(current, flag, to: !current[keyPath: flag]), shape: shape, isPrefix: false)
                report(view)
                return
            }
            let string = storage.string as NSString
            var pieces: [(range: NSRange, style: MarkdownStyle)] = []
            storage.enumerateAttribute(.markdownStyle, in: range) { value, piece, _ in
                guard string.substring(with: piece).contains(where: { $0 != "\n" }) else { return }
                pieces.append((piece, (value as? MarkdownStyleValue)?.style ?? MarkdownStyle()))
            }
            let isOn = !pieces.allSatisfy { $0.style[keyPath: flag] }
            storage.beginEditing()
            for piece in pieces {
                storage.addAttribute(.markdownStyle, value: MarkdownStyleValue(toggled(piece.style, flag, to: isOn)), range: piece.range)
            }
            storage.endEditing()
            view.selectedRange = range
            commit(view)
        }

        private func setLines(_ kind: MarkdownBlockKind, in view: UITextView) {
            let storage = view.textStorage
            let texts = storage.string.components(separatedBy: "\n")
            let shapes = RichText.shapes(texts)
            let selection = view.selectedRange
            let starts = lineStarts(texts)
            let touched = texts.indices.filter { index in
                let end = starts[index] + texts[index].utf16.count
                return !shapes[index].isVerbatim && end >= selection.location && starts[index] <= selection.upperBound
            }
            guard !touched.isEmpty else { return }
            let isRemoving = touched.allSatisfy { shapes[$0].kind == kind }
            var edits: [(range: NSRange, replacement: String)] = []
            for (number, index) in touched.enumerated() {
                let replacement: String
                switch kind {
                case _ where isRemoving: replacement = ""
                case .heading: replacement = "# "
                case .numbered: replacement = "\(number + 1). "
                default: replacement = "- "
                }
                edits.append((NSRange(location: starts[index], length: String(texts[index].prefix(shapes[index].prefixLength)).utf16.count), replacement))
            }
            replace(edits, in: view, keeping: selection)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onChange: onChange, onStyleState: onStyleState)
        coordinator.styleSerial = styleRequest?.serial ?? 0
        coordinator.zoom = zoom
        coordinator.color = color
        coordinator.paperStyle = paperStyle
        return coordinator
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.clipsToBounds = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.autocorrectionType = .default
        view.delegate = context.coordinator
        view.tintColor = UIColor(Palette.accent)
        context.coordinator.load(text, into: view)
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, TextRhythm.rowGap * zoom))
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        coordinator.onStyleState = onStyleState
        if text != coordinator.markdown {
            coordinator.zoom = zoom
            coordinator.color = color
            coordinator.paperStyle = paperStyle
            coordinator.load(text, into: view)
        } else if coordinator.zoom != zoom || coordinator.color != color || coordinator.paperStyle != paperStyle {
            coordinator.zoom = zoom
            coordinator.color = color
            coordinator.paperStyle = paperStyle
            let selection = view.selectedRange
            coordinator.restyle(view)
            view.selectedRange = selection
        }
        if let styleRequest, styleRequest.serial != coordinator.styleSerial {
            coordinator.styleSerial = styleRequest.serial
            DispatchQueue.main.async {
                coordinator.perform(styleRequest.command, in: view)
            }
        }
    }
}
