import NotesCore
import SwiftUI
import UIKit

struct CanvasCallbacks {
    var onCameraChange: (CanvasCamera) -> Void
    var onStroke: (Tool, String, [Point]) -> Void
    var onErase: ([String]) -> Void
    var onTextTap: (Point, String?) -> Void
    var onTextMove: (String, TextBox) -> Void
    var onInput: () -> Void
    var onHold: (CGPoint) -> Void
    var onHoldMove: (CGPoint) -> Void
    var onHoldEnd: (CGPoint) -> Void
}

struct CanvasView: UIViewRepresentable {
    let page: Page
    let tool: CanvasTool
    let inkColor: String
    let showsGuides: Bool
    let hiddenElementIds: Set<String>
    let isReadOnly: Bool
    let fitRequest: Int
    let callbacks: CanvasCallbacks

    final class Coordinator {
        var fitRequest = 0
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.fitRequest = fitRequest
        return coordinator
    }

    func makeUIView(context: Context) -> InkCanvasView {
        let view = InkCanvasView(frame: .zero)
        configure(view)
        return view
    }

    func updateUIView(_ view: InkCanvasView, context: Context) {
        configure(view)
        if context.coordinator.fitRequest != fitRequest {
            context.coordinator.fitRequest = fitRequest
            view.fit()
        }
    }

    private func configure(_ view: InkCanvasView) {
        view.page = page
        view.tool = tool
        view.inkColor = inkColor
        view.showsGuides = showsGuides
        view.hiddenElementIds = hiddenElementIds
        view.isReadOnly = isReadOnly
        view.onCameraChange = callbacks.onCameraChange
        view.onStroke = callbacks.onStroke
        view.onErase = callbacks.onErase
        view.onTextTap = callbacks.onTextTap
        view.onTextMove = callbacks.onTextMove
        view.onInput = callbacks.onInput
        view.onHold = callbacks.onHold
        view.onHoldMove = callbacks.onHoldMove
        view.onHoldEnd = callbacks.onHoldEnd
    }
}

struct TextBlockEditor: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let color: String
    let onChange: (String) -> Void

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textViewDidChange(_ textView: UITextView) {
            onChange(textView.text)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
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
        if view.text != text {
            view.text = text
        }
        apply(to: view)
    }

    private func apply(to view: UITextView) {
        let attributes = PageRenderer.textAttributes(fontSize: fontSize, color: UIColor(hex: color))
        if view.typingAttributes[.font] as? UIFont != attributes[.font] as? UIFont {
            view.typingAttributes = attributes
            let selection = view.selectedRange
            view.attributedText = NSAttributedString(string: view.text, attributes: attributes)
            view.selectedRange = selection
        }
    }
}
