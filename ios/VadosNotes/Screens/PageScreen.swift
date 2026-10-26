import NotesCore
import SwiftUI

final class CameraHolder {
    var camera = CanvasCamera()
}

struct PageScreen: View {
    let notebookId: String
    let pageId: String

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController
    @AppStorage("showsGuides") private var showsGuides = true
    @AppStorage("tool") private var toolName = Tool.pen.rawValue
    @AppStorage("isErasing") private var isErasing = false
    @AppStorage("isTyping") private var isTyping = false
    @AppStorage("penColor") private var penColor = Tokens.shared.tools.pen.colors[0]
    @AppStorage("pencilColor") private var pencilColor = Tokens.shared.tools.pencil.colors[0]
    @AppStorage("markerColor") private var markerColor = Tokens.shared.tools.marker.colors[0]
    @State private var fitRequest = 0
    @State private var overlayCamera: CanvasCamera?
    @State private var cameraHolder = CameraHolder()

    private var inkTool: Tool {
        Tool(rawValue: toolName) ?? .pen
    }

    private var canvasTool: CanvasTool {
        if isTyping { return .text }
        if isErasing { return .eraser }
        return .ink(inkTool)
    }

    var body: some View {
        let pages = library.pages(in: notebookId)
        let index = pages.firstIndex { $0.id == pageId }
        VStack(spacing: 0) {
            TopBar(
                title: library.notebook(notebookId)?.title ?? "Notebook",
                label: index.map { "Page \($0 + 1) / \(pages.count)" } ?? "Page",
                onBack: { navigator.go(.notebook(notebookId)) }
            ) {
                if library.isReadOnly(pageId) {
                    MicroLabel(text: "Read only", color: Palette.destructive)
                }
                SyncBadge(sync: library.sync)
            }
            .padding(.bottom, 12)
            ZStack(alignment: .bottom) {
                if let page = library.page(pageId) {
                    canvas(for: page)
                } else {
                    VStack(spacing: 10) {
                        Spacer()
                        MicroLabel(text: "This page was deleted")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                PopBar(groups: barGroups(pages: pages, index: index))
                    .padding(.bottom, 24)
            }
        }
        .background(KeyboardCommands(onUndo: { library.undo(pageId) }, onRedo: { library.redo(pageId) }))
    }

    @ViewBuilder
    private func canvas(for page: Page) -> some View {
        let session = library.textEditing.flatMap { $0.pageId == pageId ? $0 : nil }
        ZStack(alignment: .topLeading) {
            CanvasView(
                page: page,
                tool: canvasTool,
                inkColor: color(for: inkTool),
                showsGuides: showsGuides,
                hiddenElementIds: session.map { Set([$0.element.id]) } ?? [],
                isReadOnly: library.isReadOnly(pageId),
                fitRequest: fitRequest,
                callbacks: callbacks()
            )
            if let session, let camera = overlayCamera, let box = session.element.box {
                let fontSize = CGFloat(session.element.fontSize ?? Tokens.shared.text.fontSize) * camera.scale
                TextBlockEditor(
                    text: session.element.content ?? "",
                    fontSize: fontSize,
                    color: session.element.color ?? Tokens.shared.text.color,
                    onChange: { library.updateText($0) }
                )
                .frame(width: CGFloat(box.width) * camera.scale)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(Rectangle().stroke(Palette.accent, lineWidth: 1).padding(-6))
                .offset(x: CGFloat(box.x) * camera.scale + camera.offset.x, y: CGFloat(box.y) * camera.scale + camera.offset.y)
                .transition(.pop)
            }
        }
        .clipped()
    }

    private func callbacks() -> CanvasCallbacks {
        CanvasCallbacks(
            onCameraChange: { camera in
                cameraHolder.camera = camera
                if library.textEditing != nil {
                    overlayCamera = camera
                }
            },
            onStroke: { tool, color, points in
                library.addStroke(to: pageId, tool: tool, color: color, width: InkStyle.tokens(for: tool).width, points: points)
            },
            onErase: { ids in library.erase(ids, on: pageId) },
            onTextTap: { point, elementId in
                if library.textEditing != nil {
                    library.finishText()
                    return
                }
                overlayCamera = cameraHolder.camera
                if let elementId {
                    library.editText(elementId, on: pageId)
                } else {
                    library.beginText(on: pageId, at: point)
                }
            },
            onTextMove: { elementId, box in library.moveText(elementId, on: pageId, to: box) },
            onInput: { library.noteInput(on: pageId) },
            onHold: { point in showPageMenu(around: CGRect(origin: point, size: .zero), isFromCanvas: true) },
            onHoldMove: { point in menu.drag(to: point) },
            onHoldEnd: { point in menu.release(at: point) }
        )
    }

    private func barGroups(pages: [Page], index: Int?) -> [[PopBarItem]] {
        if library.textEditing?.pageId == pageId {
            return [[
                PopBarItem(id: "typing", glyph: .text, tint: Palette.accent, isActive: true, action: {}),
                PopBarItem(id: "finish-text", glyph: .check, tint: Palette.create, isActive: true, action: { library.finishText() }),
            ]]
        }
        let tools: [PopBarItem] = [
            inkItem(.pen, glyph: .pen),
            inkItem(.pencil, glyph: .pencil),
            inkItem(.marker, glyph: .marker),
            PopBarItem(id: "eraser", glyph: .eraser, tint: Palette.destructive, isActive: canvasTool == .eraser, action: {
                isTyping = false
                isErasing = true
            }),
            PopBarItem(id: "text", glyph: .text, tint: Palette.accent, isActive: canvasTool == .text, action: {
                isErasing = false
                isTyping = true
            }),
        ]
        let history: [PopBarItem] = [
            PopBarItem(id: "undo", glyph: .undo, isEnabled: library.canUndo(pageId), action: { library.undo(pageId) }),
            PopBarItem(id: "redo", glyph: .redo, isEnabled: library.canRedo(pageId), action: { library.redo(pageId) }),
        ]
        let more: [PopBarItem] = [
            PopBarItem(id: "page-menu", glyph: .more, action: {}, onTapAt: { frame in showPageMenu(around: frame, isFromCanvas: false) }),
        ]
        return [tools, history, more]
    }

    private func inkItem(_ tool: Tool, glyph: Glyph) -> PopBarItem {
        let color = color(for: tool)
        let isActive = canvasTool == .ink(tool)
        return PopBarItem(
            id: tool.rawValue,
            glyph: glyph,
            tint: Palette.isLight(color) ? Color(hex: color) : Palette.textBright,
            isActive: isActive,
            swatch: Color(hex: color),
            action: {
                isErasing = false
                isTyping = false
                toolName = tool.rawValue
            },
            onHold: { frame in showColorMenu(for: tool, around: frame) }
        )
    }

    private func color(for tool: Tool) -> String {
        switch tool {
        case .pen: return penColor
        case .pencil: return pencilColor
        case .marker: return markerColor
        }
    }

    private func setColor(_ color: String, for tool: Tool) {
        switch tool {
        case .pen: penColor = color
        case .pencil: pencilColor = color
        case .marker: markerColor = color
        }
        isErasing = false
        isTyping = false
        toolName = tool.rawValue
    }

    private func showColorMenu(for tool: Tool, around frame: CGRect) {
        let colors = InkStyle.tokens(for: tool).colors
        let current = color(for: tool)
        let slots = colors.enumerated().map { position, color in
            MenuSlot(position: position, title: color, role: .ink, swatch: color, isActive: color == current, handler: { setColor(color, for: tool) })
        }
        menu.present(slots, columns: 2, around: frame, title: tool.rawValue)
    }

    private func showPageMenu(around frame: CGRect, isFromCanvas: Bool) {
        let pages = library.pages(in: notebookId)
        let index = pages.firstIndex { $0.id == pageId }
        let page = library.page(pageId)
        let isReadOnly = library.isReadOnly(pageId)
        let slots = MenuSlot.fromTokens(
            Tokens.shared.menus.page,
            title: { action in
                switch action {
                case "previous_page": return "Previous"
                case "next_page": return "Next"
                case "new_page": return "New page"
                case "expand_columns": return "Add column"
                case "expand_rows": return "Add row"
                case "import": return "Import"
                case "toggle_guides": return showsGuides ? "Guides off" : "Guides on"
                case "fit_page": return "Fit page"
                case "delete_page": return "Delete page"
                default: return action
                }
            },
            isEnabled: { action in
                switch action {
                case "previous_page": return (index ?? 0) > 0
                case "next_page": return index.map { $0 < pages.count - 1 } ?? false
                case "expand_columns", "expand_rows": return page != nil && !isReadOnly
                case "import": return false
                case "delete_page": return page != nil
                default: return true
                }
            },
            perform: { action in
                switch action {
                case "previous_page":
                    if let index, index > 0 { navigator.go(.page(notebookId: notebookId, pageId: pages[index - 1].id)) }
                case "next_page":
                    if let index, index < pages.count - 1 { navigator.go(.page(notebookId: notebookId, pageId: pages[index + 1].id)) }
                case "new_page":
                    let created = library.createPage(in: notebookId)
                    navigator.go(.page(notebookId: notebookId, pageId: created.id))
                case "expand_columns":
                    library.expand(pageId, columns: true)
                case "expand_rows":
                    library.expand(pageId, columns: false)
                case "toggle_guides":
                    showsGuides.toggle()
                case "fit_page":
                    fitRequest += 1
                case "delete_page":
                    library.deletePage(pageId)
                    navigator.go(.notebook(notebookId))
                default:
                    break
                }
            }
        )
        if isFromCanvas {
            menu.present(slots, at: frame.origin, title: "Page")
        } else {
            menu.present(slots, around: frame, title: "Page")
        }
    }
}

private struct KeyboardCommands: View {
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        ZStack {
            Button("Undo", action: onUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo", action: onRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
