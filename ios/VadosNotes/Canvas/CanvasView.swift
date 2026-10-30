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
