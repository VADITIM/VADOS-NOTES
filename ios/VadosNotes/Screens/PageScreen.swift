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
    @EnvironmentObject private var preferences: Preferences
    @State private var fitRequest = 0
    @State private var overlayCamera: CanvasCamera?
    @State private var cameraHolder = CameraHolder()
    @State private var topBarBottom: CGFloat = 0
    @State private var subNavKey: String?
    @State private var panelKey: String?

    private static let previewDiameterRange: (CGFloat, CGFloat) = (4, 20)
    private static let millimetresPerPoint = 0.35278

    private var activeTool: ActiveTool {
        preferences.activeTool
    }

    private var canvasTool: CanvasTool {
        switch activeTool {
        case .text: return .text
        case .eraser: return .eraser(preferences.eraserMode)
        case .pen: return .ink(.pen)
        case .marker: return .ink(.marker)
        }
    }

    private var session: TextEditingSession? {
        library.textEditing.flatMap { $0.pageId == pageId ? $0 : nil }
    }

    var body: some View {
        let _ = library.revision
        let _ = preferences.revision
        GeometryReader { proxy in
            let canvasTop = proxy.frame(in: .global).minY
            ZStack(alignment: .topLeading) {
                if let page = library.page(pageId) {
                    canvas(for: page, topInset: max(0, topBarBottom - canvasTop))
                } else {
                    VStack {
                        Spacer()
                        MicroLabel(text: "This note was deleted")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                topBar
                toolNav
            }
            .onPreferenceChange(TopBarHeightKey.self) { topBarBottom = $0 }
        }
        .background(KeyboardCommands(onUndo: { library.undo(pageId) }, onRedo: { library.redo(pageId) }))
        .onChange(of: session?.element.id) { _, _ in
            subNavKey = nil
            panelKey = nil
        }
    }

    private var topBar: some View {
        TopBar(
            title: library.page(pageId).map { library.noteTitle($0) } ?? "Note",
            label: library.notebook(notebookId)?.title ?? "Folder",
            onBack: { navigator.go(.notebook(notebookId)) },
            onTitle: { navigator.show(.renameNote(pageId)) }
        ) {
            if library.isReadOnly(pageId) {
                MicroLabel(text: "Read only", color: Palette.destructive)
            }
            SettingsButton()
        } below: {
            RoundIconButton(glyph: "undo", color: Palette.navigation, isTinted: true, isEnabled: library.canUndo(pageId)) { library.undo(pageId) }
            RoundIconButton(glyph: "redo", color: Palette.importAsset, isTinted: true, isEnabled: library.canRedo(pageId)) { library.redo(pageId) }
        }
    }

    @ViewBuilder
    private func canvas(for page: Page, topInset: CGFloat) -> some View {
        let inkTool = canvasTool.inkTool
        ZStack(alignment: .topLeading) {
            CanvasView(
                page: page,
                tool: canvasTool,
                inkColor: inkTool.map { preferences.color($0) } ?? "#1A1A1A",
                inkWidth: inkTool.map { preferences.width($0) } ?? 0.5,
                eraserRadius: preferences.eraserRadius,
                paperStyle: preferences.paperStyle,
                showsGuides: preferences.showsGuides,
                showsDividers: preferences.showsDividers,
                hiddenElementIds: session.map { Set([$0.element.id]) } ?? [],
                isReadOnly: library.isReadOnly(pageId),
                topInset: topInset,
                fitRequest: fitRequest,
                callbacks: callbacks()
            )
            if let session, let camera = overlayCamera, let box = session.element.box {
                let fontSize = CGFloat(session.element.fontSize ?? Tokens.shared.text.fontSize) * camera.scale
                TextBlockEditor(
                    text: session.element.content ?? "",
                    fontSize: fontSize,
                    color: UIColor(hex: Palette.inkOnPaper(session.element.color ?? Tokens.shared.text.color, style: preferences.paperStyle)),
                    onChange: { library.updateText($0) }
                )
                .frame(width: CGFloat(box.width) * camera.scale)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(Rectangle().stroke(Palette.borderHover, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).padding(-6).opacity((session.element.content ?? "").isEmpty ? 0 : 1))
                .offset(x: CGFloat(box.x) * camera.scale + camera.offset.x, y: CGFloat(box.y) * camera.scale + camera.offset.y)
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
            onStroke: { tool, color, pieces, width in
                library.addStrokes(to: pageId, tool: tool, color: color, width: width, pieces: pieces)
            },
            onErase: { ids in library.erase(ids, on: pageId) },
            onEraseArea: { replacements in library.replaceStrokes(on: pageId, replacements) },
            onTextTap: { point, elementId in
                if library.textEditing != nil {
                    library.finishText()
                    return
                }
                overlayCamera = cameraHolder.camera
                if let elementId {
                    library.editText(elementId, on: pageId)
                } else if let page = library.page(pageId) {
                    let fontSize = preferences.textFontSize
                    let height = Double(MarkdownText.lineHeight(CGFloat(fontSize)))
                    let box = Ink.clampBox(TextBox(x: point.x, y: point.y, width: Tokens.shared.text.boxWidth), extent: page.extent, height: height)
                    library.beginText(on: pageId, at: Point(x: box.x, y: box.y), fontSize: fontSize)
                }
            },
            onTextMove: { elementId, box in library.moveText(elementId, on: pageId, to: box) },
            onInput: {
                library.noteInput(on: pageId)
                closeSubNav()
            },
            onHold: { point in showPageMenu(around: CGRect(origin: point, size: .zero), isFromCanvas: true) },
            onHoldMove: { point in menu.drag(to: point) },
            onHoldEnd: { point in menu.release(at: point) },
            onUndo: { library.undo(pageId) },
            onRedo: { library.redo(pageId) }
        )
    }

    private func closeSubNav() {
        withAnimation(Motion.backIn(Motion.overlayLeaveMilliseconds)) {
            subNavKey = nil
            panelKey = nil
        }
    }

    private func toggleSubNav(_ key: String) {
        withAnimation(Motion.backOut(Motion.stateMilliseconds)) {
            panelKey = nil
            subNavKey = subNavKey == key ? nil : key
        }
    }

    private func togglePanel() {
        withAnimation(Motion.backOut(Motion.overlayEnterMilliseconds)) {
            panelKey = panelKey == nil ? "wheel-\(subNavKey ?? "")" : nil
        }
    }

    private func displayColor(_ tool: Tool) -> String {
        Palette.inkOnPaper(preferences.color(tool), style: preferences.paperStyle)
    }

    private static func pointSize(_ millimetres: Double) -> String {
        String(Int((millimetres / millimetresPerPoint).rounded()))
    }

    private var navFace: String {
        session == nil ? "page-tools" : "page-typing"
    }

    private var navGroups: [[NavItem]] {
        if let session {
            let color = Palette.inkOnPaper(session.element.color ?? Tokens.shared.text.color, style: preferences.paperStyle)
            return [[
                NavItem(id: "text-size", caption: Self.pointSize(session.element.fontSize ?? preferences.textFontSize), label: "Font size", action: { _ in toggleSubNav("text-size") }),
                NavItem(id: "text-color", glyph: "text", label: "Text colour", tint: Palette.isLight(color) ? Color(hex: color) : Palette.textBright, isTinted: true, swatch: Color(hex: color), action: { _ in toggleSubNav("text-color") }),
            ], [
                NavItem(id: "finish-text", glyph: "check", label: "Done", tint: Palette.create, isTinted: true, action: { _ in library.finishText() }),
            ]]
        }
        let tools: [NavItem] = ActiveTool.drawing.compactMap { active in
            guard let tool = active.inkTool else { return nil }
            let color = displayColor(tool)
            return NavItem(id: active.rawValue, glyph: active.rawValue, label: active.rawValue.capitalized, tint: Palette.isLight(color) ? Color(hex: color) : Palette.textBright, swatch: Color(hex: color), action: { _ in press(active) })
        } + [
            NavItem(id: "eraser", glyph: "eraser", label: "Eraser", tint: Palette.destructive, action: { _ in press(.eraser) }),
            NavItem(id: "text", glyph: "text", label: "Text", tint: Palette.accent, action: { _ in press(.text) }),
        ]
        let more = [NavItem(id: "page-menu", glyph: "more", label: "Page menu", action: { frame in showPageMenu(around: frame, isFromCanvas: false) })]
        return [tools, more]
    }

    private func press(_ tool: ActiveTool) {
        if activeTool == tool {
            toggleSubNav(tool == .text ? "text-size" : tool.rawValue)
            return
        }
        closeSubNav()
        preferences.setActiveTool(tool)
    }

    private var toolNav: some View {
        ToolNav(
            face: navFace,
            groups: navGroups,
            selectedId: session == nil ? activeTool.rawValue : nil,
            subNavKey: subNavKey,
            panelKey: panelKey,
            onCarry: closeSubNav,
            subNav: { orientation in subNav(orientation) },
            panel: { panel }
        )
    }

    @ViewBuilder
    private var panel: some View {
        if let key = subNavKey {
            switch key {
            case "pen", "marker":
                if let tool = Tool(rawValue: key) {
                    ColorPanel(color: displayColor(tool)) { hex in
                        preferences.setColor(Palette.inkOnPaper(hex, style: preferences.paperStyle), for: tool)
                    }
                }
            case "text-color":
                ColorPanel(color: Palette.inkOnPaper(session?.element.color ?? Tokens.shared.text.color, style: preferences.paperStyle)) { hex in
                    library.styleText(color: Palette.inkOnPaper(hex, style: preferences.paperStyle))
                }
            default:
                EmptyView()
            }
        }
    }

    private static func share(_ value: Double, _ range: [Double]) -> Double {
        log(value / range[0]) / log(range[1] / range[0])
    }

    private static func value(_ share: Double, _ range: [Double]) -> Double {
        range[0] * pow(range[1] / range[0], share)
    }

    private static func previewDiameter(_ share: Double) -> CGFloat {
        previewDiameterRange.0 + (previewDiameterRange.1 - previewDiameterRange.0) * CGFloat(share)
    }

    @ViewBuilder
    private func subNav(_ orientation: NavOrientation) -> some View {
        switch subNavKey ?? "" {
        case "pen":
            inkControls(.pen, orientation: orientation)
        case "marker":
            inkControls(.marker, orientation: orientation)
        case "eraser":
            eraserControls(orientation: orientation)
        case "text-size":
            textSizeControls(orientation: orientation)
        case "text-color":
            textColorControls(orientation: orientation)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func inkControls(_ tool: Tool, orientation: NavOrientation) -> some View {
        let range = Preferences.inkTokens(tool).widthRange ?? [0.2, 2]
        let width = preferences.width(tool)
        let current = preferences.color(tool).uppercased()
        let inkColor = Color(hex: displayColor(tool)).opacity(max(0.6, Preferences.inkTokens(tool).opacity))
        SizeSlider(orientation: orientation, share: Self.share(width, range), previewDiameter: Self.previewDiameter(Self.share(width, range)), previewColor: inkColor) { share in
            preferences.setWidth(Self.value(share, range), for: tool)
        }
        NavSeparator(orientation: orientation)
        ForEach(preferences.widthPresets(tool), id: \.self) { preset in
            SwatchButton(color: inkColor, diameter: Self.previewDiameter(Self.share(preset, range)), isSelected: Preferences.isSameWidth(preset, width), isSizePreset: true, orientation: orientation, onSelect: { preferences.setWidth(preset, for: tool) }, onRemove: { preferences.removeWidthPreset(preset, for: tool) })
                .transition(.pop)
        }
        NavIconButton(glyph: "plus", isEnabled: !preferences.widthPresets(tool).contains { Preferences.isSameWidth($0, width) }, orientation: orientation) {
            preferences.addWidthPreset(width, for: tool)
        }
        NavSeparator(orientation: orientation)
        ForEach(preferences.colorPresets(tool), id: \.self) { color in
            SwatchButton(color: Color(hex: Palette.inkOnPaper(color, style: preferences.paperStyle)), isSelected: color.uppercased() == current, orientation: orientation, onSelect: { preferences.setColor(color, for: tool) }, onRemove: { preferences.removeColorPreset(color, for: tool) })
                .transition(.pop)
        }
        NavIconButton(glyph: "plus", isEnabled: !preferences.colorPresets(tool).contains(current), orientation: orientation) {
            preferences.addColorPreset(current, for: tool)
        }
        NavSeparator(orientation: orientation)
        WheelButton(isOpen: panelKey != nil, orientation: orientation, action: togglePanel)
    }

    @ViewBuilder
    private func eraserControls(orientation: NavOrientation) -> some View {
        let range = Tokens.shared.tools.eraser.radiusRange
        let share = Self.share(preferences.eraserRadius, range)
        SizeSlider(orientation: orientation, share: share, previewDiameter: Self.previewDiameter(share), previewColor: Palette.destructive.opacity(0.85)) { next in
            preferences.setEraserRadius(Self.value(next, range))
        }
        NavSeparator(orientation: orientation)
        NavIconButton(glyph: "erase_stroke", tint: Palette.destructive, isSelected: preferences.eraserMode == .stroke, orientation: orientation) {
            preferences.setEraserMode(.stroke)
        }
        NavIconButton(glyph: "erase_area", tint: Palette.destructive, isSelected: preferences.eraserMode == .area, orientation: orientation) {
            preferences.setEraserMode(.area)
        }
    }

    private func chooseTextSize(_ size: Double) {
        preferences.setTextFontSize(size)
        library.styleText(fontSize: preferences.textFontSize)
    }

    @ViewBuilder
    private func textSizeControls(orientation: NavOrientation) -> some View {
        let range = Tokens.shared.text.fontSizeRange
        let size = session?.element.fontSize ?? preferences.textFontSize
        let share = Self.share(size, range)
        SizeSlider(orientation: orientation, share: share, previewDiameter: Self.previewDiameter(share), previewColor: Palette.textBright) { next in
            chooseTextSize(Self.value(next, range))
        }
        NavSeparator(orientation: orientation)
        ForEach(Tokens.shared.text.fontSizePresets, id: \.self) { preset in
            CaptionButton(caption: Self.pointSize(preset), isSelected: Self.pointSize(preset) == Self.pointSize(size)) {
                chooseTextSize(preset)
            }
        }
    }

    @ViewBuilder
    private func textColorControls(orientation: NavOrientation) -> some View {
        let current = (session?.element.color ?? Tokens.shared.text.color).uppercased()
        ForEach(Tokens.shared.text.colors, id: \.self) { color in
            SwatchButton(color: Color(hex: Palette.inkOnPaper(color, style: preferences.paperStyle)), isSelected: color.uppercased() == current, orientation: orientation, onSelect: { library.styleText(color: color.uppercased()) })
        }
        NavSeparator(orientation: orientation)
        WheelButton(isOpen: panelKey != nil, orientation: orientation, action: togglePanel)
    }

    private func showPageMenu(around frame: CGRect, isFromCanvas: Bool) {
        let pages = library.pages(in: notebookId)
        let index = pages.firstIndex { $0.id == pageId }
        let page = library.page(pageId)
        let isReadOnly = library.isReadOnly(pageId)
        let showsGuides = preferences.showsGuides
        let showsDividers = preferences.showsDividers
        let slots = MenuSlot.fromTokens(
            Tokens.shared.menus.page,
            title: { action in
                switch action {
                case "previous_page": return "Previous note"
                case "next_page": return "Next note"
                case "new_page": return "New note"
                case "expand_columns": return "Add column"
                case "expand_rows": return "Add row"
                case "import": return "Import"
                case "toggle_guides": return showsGuides ? "Guides off" : "Guides on"
                case "toggle_dividers": return showsDividers ? "Cell lines off" : "Cell lines on"
                case "fit_page": return "Fit page"
                case "delete_page": return "Delete note"
                default: return action
                }
            },
            isEnabled: { action in
                switch action {
                case "previous_page": return (index ?? 0) > 0
                case "next_page": return index.map { $0 < pages.count - 1 } ?? false
                case "expand_columns", "expand_rows": return page != nil && !isReadOnly
                case "toggle_dividers": return (page?.extent.cellCount ?? 1) > 1
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
                    navigator.show(.newNote(notebookId: notebookId))
                case "expand_columns":
                    library.expand(pageId, columns: true)
                case "expand_rows":
                    library.expand(pageId, columns: false)
                case "toggle_guides":
                    preferences.setShowsGuides(!showsGuides)
                case "toggle_dividers":
                    preferences.setShowsDividers(!showsDividers)
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
            menu.present(slots, at: frame.origin, title: "Note")
        } else {
            menu.present(slots, around: frame, title: "Note")
        }
    }
}

private extension CanvasTool {
    var inkTool: Tool? {
        if case .ink(let tool) = self {
            return tool
        }
        return nil
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
