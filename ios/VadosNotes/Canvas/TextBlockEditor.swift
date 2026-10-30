import NotesCore
import SwiftUI
import UIKit

struct TextStyleState: Equatable {
    var style = MarkdownStyle()
    var lineKind: MarkdownBlockKind = .paragraph
}

enum TextStyleCommand: Equatable {
    case inline(WritableKeyPath<MarkdownStyle, Bool>)
    case line(MarkdownBlockKind)
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
    let focusRequest: Int
    let styleRequest: TextStyleRequest?
    let onChange: (String) -> Void
    let onStyleState: (TextStyleState) -> Void

    private static let inlineFlags: [WritableKeyPath<MarkdownStyle, Bool>] = [\.isBold, \.isItalic, \.isStruck, \.isUnderlined, \.isDashedUnderlined, \.isCode]
    private static let prefixShade: CGFloat = 0.45

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void
        var onStyleState: (TextStyleState) -> Void
        var focusRequest = 0
        var styleSerial = 0
        var markdown = ""
        var zoom: CGFloat = 1
        var color: UIColor = .white
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
            for (text, shape) in zip(texts, shapes) {
                let length = text.utf16.count
                let paragraph = NSRange(location: location, length: min(length + 1, storage.length - location))
                let prefixEnd = location + String(text.prefix(shape.prefixLength)).utf16.count
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
                    storage.setAttributes(attributes(piece.style, shape: shape, isPrefix: piece.range.location < prefixEnd), range: piece.range)
                }
                location += length + 1
            }
            storage.endEditing()
        }

        func attributes(_ style: MarkdownStyle, shape: RichLineShape, isPrefix: Bool) -> [NSAttributedString.Key: Any] {
            var look = style
            if shape.isVerbatim {
                look = MarkdownStyle(isCode: shape.kind == .code)
            } else if isPrefix {
                look = MarkdownStyle(isBold: shape.kind == .heading)
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
            state.lineKind = lineShape(at: range.location, in: view).kind
            if range.length > 0 {
                let string = view.textStorage.string as NSString
                var flags = Dictionary(uniqueKeysWithValues: TextBlockEditor.inlineFlags.map { ($0, true) })
                view.textStorage.enumerateAttribute(.markdownStyle, in: range) { value, piece, _ in
                    guard string.substring(with: piece).contains(where: { $0 != "\n" }) else { return }
                    let style = (value as? MarkdownStyleValue)?.style ?? MarkdownStyle()
                    for flag in TextBlockEditor.inlineFlags where !style[keyPath: flag] {
                        flags[flag] = false
                    }
                }
                for flag in TextBlockEditor.inlineFlags {
                    state.style[keyPath: flag] = flags[flag] ?? false
                }
            } else {
                state.style = (view.typingAttributes[.markdownStyle] as? MarkdownStyleValue)?.style ?? MarkdownStyle()
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
            }
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
            var starts: [Int] = []
            var location = 0
            for text in texts {
                starts.append(location)
                location += text.utf16.count + 1
            }
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
            var start = selection.location
            var end = selection.upperBound
            for edit in edits {
                let delta = edit.replacement.utf16.count - edit.range.length
                if edit.range.upperBound <= start {
                    start += delta
                } else if edit.range.location < start {
                    start = edit.range.location + edit.replacement.utf16.count
                }
                if edit.range.upperBound <= end {
                    end += delta
                } else if edit.range.location < end {
                    end = edit.range.location + edit.replacement.utf16.count
                }
            }
            storage.beginEditing()
            for edit in edits.reversed() {
                storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: [.markdownStyle: MarkdownStyleValue(MarkdownStyle())]))
            }
            storage.endEditing()
            view.selectedRange = NSRange(location: start, length: max(0, end - start))
            commit(view)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onChange: onChange, onStyleState: onStyleState)
        coordinator.focusRequest = focusRequest
        coordinator.styleSerial = styleRequest?.serial ?? 0
        coordinator.zoom = zoom
        coordinator.color = color
        return coordinator
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
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
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            view.becomeFirstResponder()
        }
        if text != coordinator.markdown {
            coordinator.zoom = zoom
            coordinator.color = color
            coordinator.load(text, into: view)
        } else if coordinator.zoom != zoom || coordinator.color != color {
            coordinator.zoom = zoom
            coordinator.color = color
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
