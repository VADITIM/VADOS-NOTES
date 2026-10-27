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
    }
}

struct TextBlockEditor: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let color: UIColor
    let focusRequest: Int
    let onChange: (String) -> Void

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void
        var focusRequest = 0

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textViewDidChange(_ textView: UITextView) {
            onChange(textView.text)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onChange: onChange)
        coordinator.focusRequest = focusRequest
        return coordinator
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.autocorrectionType = .default
        view.delegate = context.coordinator
        view.tintColor = UIColor(Palette.accent)
        view.text = text
        apply(to: view)
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, fontSize * 1.4))
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onChange = onChange
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            view.becomeFirstResponder()
        }
        if view.text != text {
            view.text = text
        }
        apply(to: view)
    }

    private func apply(to view: UITextView) {
        let attributes = PageRenderer.textAttributes(fontSize: fontSize, color: color)
        let currentFont = view.typingAttributes[.font] as? UIFont
        let currentColor = view.typingAttributes[.foregroundColor] as? UIColor
        if currentFont != attributes[.font] as? UIFont || currentColor != color {
            view.typingAttributes = attributes
            let selection = view.selectedRange
            view.attributedText = NSAttributedString(string: view.text, attributes: attributes)
            view.selectedRange = selection
        }
    }
}
