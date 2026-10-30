import NotesCore
import SwiftUI
import UIKit

final class CameraHolder {
    var camera = CanvasCamera()
}

@MainActor
final class KeyboardObserver: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            MainActor.assumeIsolated {
                withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
                    self?.height = max(0, screenHeight - frame.minY)
                }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct PageScreen: View {
    let notebookId: String
    let pageId: String

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController
    @EnvironmentObject private var preferences: Preferences
    @StateObject private var keyboard = KeyboardObserver()
    @Namespace private var ringSpace
    @State private var overlayCamera: CanvasCamera?
    @State private var cameraHolder = CameraHolder()
    @Environment(\.chromeLayout) private var chrome
    @State private var subNavKey: String?
    @State private var lastSubNavKey: String?
    @State private var panelKey: String?
    @State private var variationColors: [String] = []
    @State private var variationMain: String?
    @State private var variationSlot: String?
    @State private var eraserReturn: ActiveTool?
    @State private var previousTool: ActiveTool?
    @State private var textFocusRequest = 0
    @State private var textDragOrigin: TextBox?
    @State private var flightTile: CGRect?
    @State private var flightProgress: CGFloat = 1
    @State private var selectionMenu: SelectionMenuRequest?
    @State private var equalWidth = Tokens.shared.tools.pen.width
    @State private var equalWidthStart: Double?

    private static let previewDiameterRange: (CGFloat, CGFloat) = (4 * NavMetrics.scale, 20 * NavMetrics.scale)
    private static let millimetresPerPoint = 0.35278
    private static let collapsedGroupCount = 2
    private static let minimumTextWidth = 20.0
    private static let handleSize = CGSize(width: 8, height: 36)
    private static let editorInset = EdgeInsets(top: 6, leading: 22, bottom: 6, trailing: 22)
    private static let equalWidthTravel: CGFloat = 240

    private var isChromeShown: Bool {
        navigator.isPageChromeShown
    }

    private var activeTool: ActiveTool {
        preferences.activeTool
    }

    private var canvasTool: CanvasTool {
        switch activeTool {
        case .text: return .text
        case .lasso: return .lasso
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
                Group {
                    if let page = library.page(pageId) {
                        canvas(for: page, topInset: max(0, chrome.bottom - canvasTop))
                    } else {
                        VStack {
                            Spacer()
                            MicroLabel(text: "This note was deleted")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .modifier(TileFlight(progress: flightProgress, tile: flightTile))
                ZStack {
                    if let selectionMenu {
                        selectionNav(selectionMenu, layer: proxy.size, origin: proxy.frame(in: .global).origin)
                            .transition(.popTogether)
                    }
                }
                toolNav
            }
        }
        .background(KeyboardCommands(onUndo: { library.undo(pageId) }, onRedo: { library.redo(pageId) }))
        .onChange(of: session?.element.id) { _, _ in
            subNavKey = nil
            panelKey = nil
        }
        .onChange(of: subNavKey) { _, key in
            if let key {
                lastSubNavKey = key
            }
        }
        .onAppear(perform: startFlight)
        .onChange(of: navigator.isChromeLeaving) { _, leaving in
            guard leaving else { return }
            library.finishText()
            withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                selectionMenu = nil
            }
        }
    }

    private func startFlight() {
        guard let tile = navigator.openingTile else {
            DispatchQueue.main.async {
                navigator.showPageChrome(true)
            }
            return
        }
        navigator.openingTile = nil
        flightTile = tile
        flightProgress = 0
        withAnimation(Motion.powerTwoOut(Motion.viewerEnterMilliseconds)) {
            flightProgress = 1
        }
        let arrival = Motion.seconds(Motion.viewerEnterMilliseconds) * Motion.shares.chromeArrival
        DispatchQueue.main.asyncAfter(deadline: .now() + arrival) {
            navigator.showPageChrome(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.viewerEnterMilliseconds)) {
            flightTile = nil
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
                showsBackdrop: preferences.showsAsciiBackground,
                inkSmoothing: preferences.inkSmoothing,
                hiddenElementIds: session.map { Set([$0.element.id]) } ?? [],
                isReadOnly: library.isReadOnly(pageId),
                topInset: topInset,
                callbacks: callbacks()
            )
            if let session, let camera = overlayCamera, let box = session.element.box {
                textEditor(session, box: box, camera: camera, extent: page.extent)
            }
        }
        .clipped()
    }

    private func textEditor(_ session: TextEditingSession, box: TextBox, camera: CanvasCamera, extent: Extent) -> some View {
        let fontSize = CGFloat(session.element.fontSize ?? Tokens.shared.text.fontSize) * camera.scale
        return TextBlockEditor(
            text: session.element.content ?? "",
            fontSize: fontSize,
            color: UIColor(hex: Palette.inkOnPaper(session.element.color ?? Tokens.shared.text.color, style: preferences.paperStyle)),
            focusRequest: textFocusRequest,
            onChange: { library.updateText($0) }
        )
        .frame(width: CGFloat(box.width) * camera.scale)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Self.editorInset)
        .overlay(Rectangle().stroke(Palette.borderHover, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .simultaneousGesture(textDrag(box: box, camera: camera, extent: extent) { origin, translation in
            TextBox(x: origin.x + translation.x, y: origin.y + translation.y, width: origin.width)
        })
        .overlay(alignment: .leading) {
            textHandle
                .offset(x: -Self.handleSize.width / 2)
                .gesture(textDrag(box: box, camera: camera, extent: extent) { origin, translation in
                    let shift = min(translation.x, origin.width - Self.minimumTextWidth)
                    return TextBox(x: origin.x + shift, y: origin.y, width: origin.width - shift)
                })
        }
        .overlay(alignment: .trailing) {
            textHandle
                .offset(x: Self.handleSize.width / 2)
                .gesture(textDrag(box: box, camera: camera, extent: extent) { origin, translation in
                    TextBox(x: origin.x, y: origin.y, width: max(Self.minimumTextWidth, origin.width + translation.x))
                })
        }
        .offset(x: CGFloat(box.x) * camera.scale + camera.offset.x - Self.editorInset.leading, y: CGFloat(box.y) * camera.scale + camera.offset.y - Self.editorInset.top)
    }

    private var textHandle: some View {
        Capsule()
            .fill(Palette.accent)
            .frame(width: Self.handleSize.width, height: Self.handleSize.height)
            .padding(12)
            .contentShape(Rectangle())
    }

    private func textDrag(box: TextBox, camera: CanvasCamera, extent: Extent, change: @escaping (TextBox, Point) -> TextBox) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let origin = textDragOrigin ?? box
                if textDragOrigin == nil {
                    textDragOrigin = box
                }
                let translation = Point(x: Double(value.translation.width / camera.scale), y: Double(value.translation.height / camera.scale))
                let height = Double(session.flatMap { PageRenderer.textRect(for: $0.element)?.height } ?? 0)
                library.placeText(Ink.clampBox(change(origin, translation), extent: extent, height: height))
            }
            .onEnded { _ in
                textDragOrigin = nil
            }
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
            onMoveElements: { ids, offset in library.moveElements(ids, on: pageId, by: offset) },
            onScaleElements: { ids, anchor, factor in library.scaleElements(ids, on: pageId, about: anchor, by: factor) },
            onSelectionMenu: { request in
                guard request != selectionMenu else { return }
                withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                    selectionMenu = request
                }
            },
            onInput: {
                library.noteInput(on: pageId)
                closePanel()
            },
            onHold: { point in showPageMenu(at: point) },
            onHoldMove: { point in menu.drag(to: point) },
            onHoldEnd: { point in menu.release(at: point) },
            onUndo: { library.undo(pageId) },
            onRedo: { library.redo(pageId) },
            onPencilTap: pencilTapped,
            onEraseLift: returnFromEraser
        )
    }

    private func closePanel() {
        guard panelKey != nil else { return }
        withAnimation(Motion.powerTwoOut(Motion.overlayLeaveMilliseconds)) {
            panelKey = nil
        }
    }

    private func pencilTapped() {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            if let eraserReturn {
                self.eraserReturn = nil
                switchTool(eraserReturn)
            } else if activeTool != .eraser {
                eraserReturn = activeTool
                switchTool(.eraser)
            } else if let previousTool {
                switchTool(previousTool)
            }
        case .switchPrevious:
            if let previousTool {
                switchTool(previousTool)
            }
        default:
            break
        }
    }

    private func returnFromEraser() {
        guard let eraserReturn else { return }
        self.eraserReturn = nil
        switchTool(eraserReturn)
    }

    private func switchTool(_ tool: ActiveTool) {
        guard tool != activeTool else { return }
        previousTool = activeTool
        Haptics.tick()
        preferences.setActiveTool(tool)
        guard subNavKey != nil else { return }
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            panelKey = nil
            switch tool {
            case .lasso: subNavKey = nil
            case .text: subNavKey = "text-size"
            default: subNavKey = tool.rawValue
            }
        }
    }

    private func closeSubNav() {
        subNavKey = nil
        panelKey = nil
    }

    private func selectionNav(_ request: SelectionMenuRequest, layer: CGSize, origin: CGPoint) -> some View {
        let range = Tokens.shared.tools.pen.widthRange ?? [0.2, 2]
        let halfWidth: CGFloat = 150
        let x = min(layer.width - halfWidth - NavMetrics.edgeMargin, max(halfWidth + NavMetrics.edgeMargin, request.frame.midX - origin.x))
        let above = request.frame.minY - origin.y - NavMetrics.besideGap - 27
        let y = above > max(chrome.bottom - origin.y, 0) + 27 ? above : request.frame.maxY - origin.y + NavMetrics.besideGap + 27
        return HStack(spacing: NavMetrics.spacing) {
            Button {
                Haptics.landed()
                library.setStrokeWidth(request.ids, on: pageId, to: equalWidth)
            } label: {
                Text("Resize to equal px".uppercased())
                    .font(Typography.monoBold(12))
                    .tracking(1)
                    .foregroundColor(Palette.textBright)
                    .padding(.horizontal, 16)
                    .frame(height: NavMetrics.itemSize(.horizontal).height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            NavSeparator(orientation: .horizontal)
            Text(Self.pixelCaption(equalWidth))
                .font(Typography.monoBold(15))
                .foregroundColor(Palette.accent)
                .frame(width: 84, height: NavMetrics.itemSize(.horizontal).height)
                .background(Capsule().fill(Palette.pressedWash))
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: NavMetrics.sizingSlop)
                        .onChanged { value in
                            let start = equalWidthStart ?? Self.share(equalWidth, range)
                            if equalWidthStart == nil {
                                equalWidthStart = start
                                Haptics.tick()
                            }
                            equalWidth = Self.value(min(1, max(0, start + Double(value.translation.width / Self.equalWidthTravel))), range)
                        }
                        .onEnded { _ in
                            equalWidthStart = nil
                            Haptics.landed()
                        }
                )
                .accessibilityLabel("Stroke width")
        }
        .padding(NavMetrics.padding)
        .background(Capsule().fill(Palette.panelSolid))
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        .fixedSize()
        .position(x: x, y: y)
    }

    private func toggleSubNav(_ key: String) {
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            panelKey = nil
            subNavKey = subNavKey == key ? nil : key
        }
    }

    private func togglePanel() {
        withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
            panelKey = isWheelOpen ? nil : "wheel-\(subNavKey ?? "")"
        }
    }

    private var isWheelOpen: Bool {
        panelKey?.hasPrefix("wheel-") ?? false
    }

    private static func variationsKey(_ tool: Tool) -> String {
        NavMetrics.pillPanelPrefix + tool.rawValue
    }

    private func isVariationAnchor(_ color: String, for tool: Tool) -> Bool {
        panelKey == Self.variationsKey(tool) && variationSlot == color.uppercased()
    }

    private func chooseColor(_ color: String, for tool: Tool) {
        preferences.setColor(color, for: tool)
        let normalized = color.uppercased()
        guard !isVariationAnchor(normalized, for: tool) else {
            closePanel()
            return
        }
        let isOpen = panelKey == Self.variationsKey(tool)
        withAnimation(isOpen ? Motion.placement : nil) {
            variationMain = normalized
            variationSlot = normalized
            variationColors = ColorVariations.around(normalized)
        }
        withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
            panelKey = Self.variationsKey(tool)
        }
    }

    private func pickVariation(_ variation: String, for tool: Tool) {
        guard let slot = variationSlot, variation != slot, !preferences.colorPresets(tool).contains(variation) else { return }
        Haptics.tick()
        preferences.replaceColorPreset(slot, with: variation, for: tool)
        preferences.setColor(variation, for: tool)
        variationSlot = variation
    }

    private func displayColor(_ tool: Tool) -> String {
        Palette.inkOnPaper(preferences.color(tool), style: preferences.paperStyle)
    }

    private static func pointSize(_ millimetres: Double) -> String {
        String(Int((millimetres / millimetresPerPoint).rounded()))
    }

    private static func pixelCaption(_ millimetres: Double) -> String {
        let pixels = millimetres / millimetresPerPoint
        return pixels < 10 ? String(format: "%.1fpx", pixels) : "\(Int(pixels.rounded()))px"
    }

    private var navFace: String {
        session == nil ? "page-tools" : "page-typing"
    }

    private var navGroups: [[NavItem]] {
        if let session {
            let color = Palette.inkOnPaper(session.element.color ?? Tokens.shared.text.color, style: preferences.paperStyle)
            return [[
                NavItem(id: "text-size", caption: Self.pointSize(session.element.fontSize ?? preferences.textFontSize), label: "Font size", sizing: textSizing(), action: { _ in toggleSubNav("text-size") }),
                NavItem(id: "text-color", glyph: "text", label: "Text colour", tint: Palette.isLight(color) ? Color(hex: color) : Palette.textBright, isTinted: true, swatch: Color(hex: color), action: { _ in toggleSubNav("text-color") }),
                NavItem(id: "edit-text", glyph: "keyboard", label: "Edit", tint: Palette.edit, isTinted: true, action: { _ in textFocusRequest += 1 }),
            ], [
                NavItem(id: "finish-text", glyph: "check", label: "Done", tint: Palette.create, isTinted: true, action: { _ in library.finishText() }),
            ]]
        }
        let tools: [NavItem] = preferences.toolOrder.compactMap { raw in
            guard let active = ActiveTool(rawValue: raw) else { return nil }
            switch active {
            case .pen, .marker:
                guard let tool = active.inkTool else { return nil }
                let color = displayColor(tool)
                return NavItem(id: active.rawValue, glyph: active.rawValue, label: active.rawValue.capitalized, tint: Palette.isLight(color) ? Color(hex: color) : Palette.textBright, swatch: Color(hex: color), sizing: inkSizing(tool), action: { _ in press(active) })
            case .eraser:
                return NavItem(id: "eraser", glyph: "eraser", label: "Eraser", tint: Palette.destructive, sizing: eraserSizing(), action: { _ in press(.eraser) })
            case .text:
                return NavItem(id: "text", glyph: "text", label: "Text", tint: Palette.accent, action: { _ in press(.text) })
            case .lasso:
                return NavItem(id: "lasso", glyph: "lasso", label: "Lasso", tint: Palette.accent, action: { _ in press(.lasso) })
            }
        }
        return [tools]
    }

    private func inkSizing(_ tool: Tool) -> NavSizing {
        let range = Preferences.inkTokens(tool).widthRange ?? [0.2, 2]
        return NavSizing(
            share: Self.share(preferences.width(tool), range),
            color: Color(hex: displayColor(tool)).opacity(max(0.6, Preferences.inkTokens(tool).opacity)),
            previewDiameter: Self.previewDiameter,
            caption: { share in Self.pixelCaption(Self.value(share, range)) },
            onChange: { share in preferences.setWidth(Self.value(share, range), for: tool) }
        )
    }

    private func eraserSizing() -> NavSizing {
        let range = Tokens.shared.tools.eraser.radiusRange
        return NavSizing(
            share: Self.share(preferences.eraserRadius, range),
            color: Palette.destructive.opacity(0.85),
            previewDiameter: Self.previewDiameter,
            caption: { share in Self.pixelCaption(Self.value(share, range) * 2) },
            onChange: { share in preferences.setEraserRadius(Self.value(share, range)) }
        )
    }

    private func textSizing() -> NavSizing {
        let range = Tokens.shared.text.fontSizeRange
        return NavSizing(
            share: Self.share(session?.element.fontSize ?? preferences.textFontSize, range),
            color: Palette.textBright,
            previewDiameter: Self.previewDiameter,
            caption: { share in Self.pointSize(Self.value(share, range)) + "pt" },
            onChange: { share in chooseTextSize(Self.value(share, range)) }
        )
    }

    private func press(_ tool: ActiveTool) {
        if activeTool == tool {
            guard tool != .lasso else { return }
            toggleSubNav(tool == .text ? "text-size" : tool.rawValue)
            return
        }
        previousTool = activeTool
        eraserReturn = nil
        preferences.setActiveTool(tool)
        if subNavKey != nil, tool != .lasso {
            withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                panelKey = nil
                subNavKey = tool == .text ? "text-size" : tool.rawValue
            }
        } else {
            closeSubNav()
        }
    }

    private var toolNav: some View {
        ToolNav(
            face: navFace,
            groups: navGroups,
            selectedId: session == nil ? activeTool.rawValue : nil,
            subNavKey: subNavKey,
            subNavigationGroups: orderedSubNavigationGroups,
            panelKey: panelKey,
            obstacles: Array(chrome.frames.values),
            keyboardHeight: keyboard.height,
            isShown: isChromeShown,
            onReorderTools: { order in preferences.setToolOrder(order) },
            onReorderSubNavigation: { order in
                if let subNavKey {
                    preferences.setSubNavigationOrder(order, for: subNavKey)
                }
            },
            panel: { key, orientation in panel(key, orientation) }
        )
    }

    @ViewBuilder
    private func panel(_ shownKey: String, _ orientation: NavOrientation) -> some View {
        if shownKey.hasPrefix(NavMetrics.pillPanelPrefix), let tool = Tool(rawValue: String(shownKey.dropFirst(NavMetrics.pillPanelPrefix.count))), let main = variationMain {
            VariationPanel(colors: variationColors, main: main, selected: variationSlot ?? main, orientation: orientation, display: { Color(hex: Palette.inkOnPaper($0, style: preferences.paperStyle)) }) { variation in
                pickVariation(variation, for: tool)
            }
        } else if let key = subNavKey {
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

    private var orderedSubNavigationGroups: [SubNavigationGroup] {
        guard let key = subNavKey ?? lastSubNavKey else { return [] }
        let groups = subNavigationGroups(key)
        let order = preferences.subNavigationOrder(key)
        return order.compactMap { id in groups.first { $0.id == id } } + groups.filter { !order.contains($0.id) }
    }

    private func group<Content: View>(_ id: String, onCollapse: ((Bool) -> Bool)? = nil, @ViewBuilder content: @escaping (NavOrientation) -> Content) -> SubNavigationGroup {
        SubNavigationGroup(id: id, content: { orientation in AnyView(content(orientation)) }, onCollapse: onCollapse)
    }

    private func isCollapsed(_ id: String, count: Int) -> Bool {
        count > Self.collapsedGroupCount && preferences.isSubNavigationGroupCollapsed(id)
    }

    private func setCollapsed(_ isCollapsing: Bool, id: String, count: Int) -> Bool {
        guard count > Self.collapsedGroupCount, isCollapsed(id, count: count) != isCollapsing else { return false }
        withAnimation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2)) {
            preferences.setSubNavigationGroupCollapsed(isCollapsing, for: id)
        }
        return true
    }

    private func subNavigationGroups(_ key: String) -> [SubNavigationGroup] {
        switch key {
        case "pen":
            return inkGroups(.pen)
        case "marker":
            return inkGroups(.marker)
        case "eraser":
            return eraserGroups()
        case "text-size":
            return [textSizeGroup()]
        case "text-color":
            return textColorGroups()
        default:
            return []
        }
    }

    private func stack(_ orientation: NavOrientation, spacing: CGFloat = 0) -> AnyLayout {
        orientation == .horizontal ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
    }

    private func inkGroups(_ tool: Tool) -> [SubNavigationGroup] {
        let range = Preferences.inkTokens(tool).widthRange ?? [0.2, 2]
        let width = preferences.width(tool)
        let current = preferences.color(tool).uppercased()
        let inkColor = Color(hex: displayColor(tool)).opacity(max(0.6, Preferences.inkTokens(tool).opacity))
        let presets = preferences.widthPresets(tool)
        let colors = preferences.colorPresets(tool)
        let sizesId = "\(tool.rawValue)-sizes"
        let coloursId = "\(tool.rawValue)-colours"
        let areSizesCollapsed = isCollapsed(sizesId, count: presets.count)
        let areColoursCollapsed = isCollapsed(coloursId, count: colors.count)
        let shownPresets = areSizesCollapsed ? Array(presets.prefix(Self.collapsedGroupCount)) : presets
        let shownColors = areColoursCollapsed ? Array(colors.prefix(Self.collapsedGroupCount)) : colors
        let collapseColours = { (isCollapsing: Bool) -> Bool in
            guard setCollapsed(isCollapsing, id: coloursId, count: colors.count) else { return false }
            if isCollapsing, panelKey == Self.variationsKey(tool) {
                closePanel()
            }
            return true
        }
        return [
            group(sizesId, onCollapse: { isCollapsing in setCollapsed(isCollapsing, id: sizesId, count: presets.count) }) { orientation in
                let layout = stack(orientation)
                layout {
                    ForEach(shownPresets, id: \.self) { preset in
                        SwatchButton(color: inkColor, diameter: Self.previewDiameter(Self.share(preset, range)), isSelected: Preferences.isSameWidth(preset, width), isSizePreset: true, orientation: orientation, ring: ("\(tool.rawValue)-size-ring", ringSpace), onSelect: { preferences.setWidth(preset, for: tool) }, onRemove: { preferences.removeWidthPreset(preset, for: tool) })
                            .transition(.elementLeave)
                    }
                    GroupEndButton(isCollapsed: areSizesCollapsed, isEnabled: areSizesCollapsed || !presets.contains { Preferences.isSameWidth($0, width) }, orientation: orientation) {
                        if areSizesCollapsed {
                            _ = setCollapsed(false, id: sizesId, count: presets.count)
                        } else {
                            preferences.addWidthPreset(width, for: tool)
                        }
                    }
                }
            },
            group(coloursId, onCollapse: collapseColours) { orientation in
                let layout = stack(orientation)
                layout {
                    ForEach(Array(shownColors.enumerated()), id: \.offset) { _, color in
                        SwatchButton(color: Color(hex: Palette.inkOnPaper(color, style: preferences.paperStyle)), isSelected: color.uppercased() == current, orientation: orientation, ring: ("\(tool.rawValue)-colour-ring", ringSpace), isPanelAnchor: isVariationAnchor(color, for: tool), onSelect: { chooseColor(color, for: tool) }, onRemove: { preferences.removeColorPreset(color, for: tool) })
                            .transition(.elementLeave)
                    }
                    GroupEndButton(isCollapsed: areColoursCollapsed, isEnabled: areColoursCollapsed || !colors.contains(current), orientation: orientation) {
                        if areColoursCollapsed {
                            _ = setCollapsed(false, id: coloursId, count: colors.count)
                        } else {
                            preferences.addColorPreset(current, for: tool)
                        }
                    }
                }
            },
            group("\(tool.rawValue)-wheel") { orientation in
                WheelButton(isOpen: isWheelOpen, orientation: orientation, action: togglePanel)
            },
        ]
    }

    private func eraserGroups() -> [SubNavigationGroup] {
        [
            group("eraser-modes") { orientation in
                let layout = stack(orientation)
                layout {
                    NavIconButton(glyph: "erase_stroke", tint: Palette.destructive, isSelected: preferences.eraserMode == .stroke, orientation: orientation, ring: ("eraser-mode-ring", ringSpace)) {
                        preferences.setEraserMode(.stroke)
                    }
                    NavIconButton(glyph: "erase_area", tint: Palette.destructive, isSelected: preferences.eraserMode == .area, orientation: orientation, ring: ("eraser-mode-ring", ringSpace)) {
                        preferences.setEraserMode(.area)
                    }
                }
            },
        ]
    }

    private func chooseTextSize(_ size: Double) {
        preferences.setTextFontSize(size)
        library.styleText(fontSize: preferences.textFontSize)
    }

    private func textSizeGroup() -> SubNavigationGroup {
        let size = session?.element.fontSize ?? preferences.textFontSize
        return group("text-sizes") { orientation in
            let layout = stack(orientation)
            layout {
                ForEach(Tokens.shared.text.fontSizePresets, id: \.self) { preset in
                    CaptionButton(caption: Self.pointSize(preset), isSelected: Self.pointSize(preset) == Self.pointSize(size), ring: ("text-size-ring", ringSpace)) {
                        chooseTextSize(preset)
                    }
                }
            }
        }
    }

    private func textColorGroups() -> [SubNavigationGroup] {
        let current = (session?.element.color ?? Tokens.shared.text.color).uppercased()
        return [
            group("text-colours") { orientation in
                let layout = stack(orientation)
                layout {
                    ForEach(Tokens.shared.text.colors, id: \.self) { color in
                        SwatchButton(color: Color(hex: Palette.inkOnPaper(color, style: preferences.paperStyle)), isSelected: color.uppercased() == current, orientation: orientation, ring: ("text-colour-ring", ringSpace), onSelect: { library.styleText(color: color.uppercased()) })
                    }
                }
            },
            group("text-wheel") { orientation in
                WheelButton(isOpen: isWheelOpen, orientation: orientation, action: togglePanel)
            },
        ]
    }

    private func showPageMenu(at point: CGPoint) {
        let page = library.page(pageId)
        let isReadOnly = library.isReadOnly(pageId)
        let showsGuides = preferences.showsGuides
        let showsDividers = preferences.showsDividers
        let actions = ["expand_columns", "expand_rows", "toggle_guides", "toggle_dividers", "delete_page"]
        let slots = MenuSlot.fromTokens(
            Tokens.shared.menus.page.filter { actions.contains($0.action) },
            title: { action in
                switch action {
                case "expand_columns": return "Add column"
                case "expand_rows": return "Add row"
                case "toggle_guides": return showsGuides ? "Guides off" : "Guides on"
                case "toggle_dividers": return showsDividers ? "Cell lines off" : "Cell lines on"
                case "delete_page": return "Delete note"
                default: return action
                }
            },
            isEnabled: { action in
                switch action {
                case "expand_columns", "expand_rows": return page != nil && !isReadOnly
                case "toggle_dividers": return (page?.extent.cellCount ?? 1) > 1
                case "delete_page": return page != nil
                default: return true
                }
            },
            perform: { action in
                switch action {
                case "expand_columns":
                    library.expand(pageId, columns: true)
                case "expand_rows":
                    library.expand(pageId, columns: false)
                case "toggle_guides":
                    preferences.setShowsGuides(!showsGuides)
                case "toggle_dividers":
                    preferences.setShowsDividers(!showsDividers)
                case "delete_page":
                    library.deletePage(pageId)
                    navigator.go(.notebook(notebookId))
                default:
                    break
                }
            }
        )
        menu.present(slots, at: point, title: "Note")
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
