import NotesCore
import SwiftUI
import UIKit

struct SelectionMenuRequest: Equatable {
    let ids: [String]
    let frame: CGRect
}

struct CanvasCallbacks {
    var onCameraChange: (CanvasCamera) -> Void
    var onStroke: (Tool, String, [[Point]], Double) -> Void
    var onErase: ([String]) -> Void
    var onEraseArea: ([StrokeReplacement]) -> Void
    var onTextTap: (Point, String?) -> Void
    var onTextMove: (String, TextBox) -> Void
    var onMoveElements: ([String], Point) -> Void
    var onScaleElements: ([String], Point, Double) -> Void
    var onSelectionMenu: (SelectionMenuRequest?) -> Void
    var onInput: () -> Void
    var onHold: (CGPoint) -> Void
    var onHoldMove: (CGPoint) -> Void
    var onHoldEnd: (CGPoint) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onPencilTap: () -> Void
    var onEraseLift: () -> Void
}

struct CanvasView: UIViewRepresentable {
    let page: Page
    let tool: CanvasTool
    let inkColor: String
    let inkWidth: Double
    let eraserRadius: Double
    let paperStyle: PaperStyle
    let showsGuides: Bool
    let showsDividers: Bool
    let showsBackdrop: Bool
    let inkSmoothing: Double
    let hiddenElementIds: Set<String>
    let isReadOnly: Bool
    let topInset: CGFloat
    let callbacks: CanvasCallbacks

    func makeUIView(context: Context) -> InkCanvasView {
        let view = InkCanvasView(frame: .zero)
        configure(view)
        return view
    }

    func updateUIView(_ view: InkCanvasView, context: Context) {
        configure(view)
    }

    private func configure(_ view: InkCanvasView) {
        view.page = page
        view.tool = tool
        view.inkColor = inkColor
        view.inkWidth = inkWidth
        view.eraserRadius = eraserRadius
        view.paperStyle = paperStyle
        view.showsGuides = showsGuides
        view.showsDividers = showsDividers
        view.showsBackdrop = showsBackdrop
        view.inkSmoothing = inkSmoothing
        view.hiddenElementIds = hiddenElementIds
        view.isReadOnly = isReadOnly
        view.topInset = topInset
        view.onCameraChange = callbacks.onCameraChange
        view.onStroke = callbacks.onStroke
        view.onErase = callbacks.onErase
        view.onEraseArea = callbacks.onEraseArea
        view.onTextTap = callbacks.onTextTap
        view.onTextMove = callbacks.onTextMove
        view.onMoveElements = callbacks.onMoveElements
        view.onScaleElements = callbacks.onScaleElements
        view.onSelectionMenu = callbacks.onSelectionMenu
        view.onInput = callbacks.onInput
        view.onHold = callbacks.onHold
        view.onHoldMove = callbacks.onHoldMove
        view.onHoldEnd = callbacks.onHoldEnd
        view.onUndo = callbacks.onUndo
        view.onRedo = callbacks.onRedo
        view.onPencilTap = callbacks.onPencilTap
        view.onEraseLift = callbacks.onEraseLift
    }
}

struct TextBlockEditor: UIViewRepresentable {
    let text: String
    let zoom: CGFloat
    let color: UIColor
    let focusRequest: Int
    let onChange: (String) -> Void

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void
        var focusRequest = 0
        var attributes: [NSAttributedString.Key: Any] = [:]

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textViewDidChange(_ textView: UITextView) {
            if textView.markedTextRange == nil, !attributes.isEmpty {
                let selection = textView.selectedRange
                textView.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textView.textStorage.length))
                textView.typingAttributes = attributes
                textView.selectedRange = selection
            }
            onChange(textView.text)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onChange: onChange)
        coordinator.focusRequest = focusRequest
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
        view.text = text
        apply(to: view, coordinator: context.coordinator)
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
        context.coordinator.onChange = onChange
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            view.becomeFirstResponder()
        }
        let isReplaced = view.text != text
        if isReplaced {
            view.text = text
        }
        apply(to: view, coordinator: context.coordinator, isForced: isReplaced)
    }

    private func apply(to view: UITextView, coordinator: Coordinator, isForced: Bool = false) {
        let attributes = TextRhythm.attributes(zoom: zoom, color: color)
        coordinator.attributes = attributes
        let currentFont = view.typingAttributes[.font] as? UIFont
        let currentColor = view.typingAttributes[.foregroundColor] as? UIColor
        if isForced || currentFont != attributes[.font] as? UIFont || currentColor != color {
            view.typingAttributes = attributes
            let selection = view.selectedRange
            view.attributedText = NSAttributedString(string: view.text, attributes: attributes)
            view.selectedRange = selection
        }
    }
}
