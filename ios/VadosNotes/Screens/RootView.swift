import NotesCore
import SwiftUI

enum Route: Hashable {
    case library
    case notebook(String)
    case page(notebookId: String, pageId: String)

    var isPage: Bool {
        if case .page = self {
            return true
        }
        return false
    }

    var folderId: String? {
        switch self {
        case .library: return nil
        case .notebook(let notebookId): return notebookId
        case .page(let notebookId, _): return notebookId
        }
    }
}

enum TileTarget: Hashable {
    case folder(String)
    case note(String)
}

enum SheetRequest: Identifiable, Equatable {
    case newFolder(parentId: String?)
    case renameFolder(String)
    case renameNote(String)
    case appearance(TileTarget)
    case move(TileTarget)
    case newNote(notebookId: String)
    case pickGroup(TileTarget, parentId: String?)
    case renameGroup(String, parentId: String?)
    case settings
    case transfer(pageId: String, mode: TransferMode)

    var id: String {
        switch self {
        case .newFolder(let parentId): return "new-folder-\(parentId ?? "root")"
        case .renameFolder(let notebookId): return "rename-folder-\(notebookId)"
        case .renameNote(let pageId): return "rename-note-\(pageId)"
        case .appearance(let target): return "appearance-\(target)"
        case .move(let target): return "move-\(target)"
        case .newNote(let notebookId): return "new-note-\(notebookId)"
        case .pickGroup(let target, _): return "pick-group-\(target)"
        case .renameGroup(let groupId, _): return "rename-group-\(groupId)"
        case .settings: return "settings"
        case .transfer(let pageId, _): return "transfer-\(pageId)"
        }
    }

    var isNaming: Bool {
        switch self {
        case .newFolder, .renameFolder, .renameNote, .newNote, .pickGroup, .renameGroup: return true
        case .appearance, .move, .settings, .transfer: return false
        }
    }

    var isFullScreen: Bool {
        switch self {
        case .settings, .transfer: return true
        default: return false
        }
    }

    var isSeeThrough: Bool {
        if case .transfer = self {
            return true
        }
        return false
    }

    var pushEdge: Edge? {
        switch self {
        case .transfer: return .leading
        case .settings: return .top
        default: return nil
        }
    }
}

@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var route: Route = .library
    @Published private(set) var sheet: SheetRequest?
    @Published private(set) var isSheetLeaving = false
    @Published private(set) var isSheetHandingOff = false
    private(set) var isHandedOff = false
    @Published private(set) var isChromeLeaving = false
    @Published private(set) var isPageChromeShown = false
    @Published var query = ""
    @Published var windowPush: CGFloat = 0
    @Published private(set) var isExplorerOpen = false
    @Published var explorerMove: TileTarget?
    private(set) var isReturningFromPage = false
    private(set) var lastPage: (notebookId: String, pageId: String)?
    var openingTile: CGRect?

    func show(_ sheet: SheetRequest?) {
        guard let sheet else {
            isSheetHandingOff = false
            guard let current = self.sheet, !isSheetLeaving else { return }
            isSheetLeaving = true
            let leave = current.isFullScreen ? Motion.sheetDropMilliseconds : current.isNaming ? Motion.keyboardMilliseconds : Motion.overlayLeaveMilliseconds
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(leave)) { [weak self] in
                guard let self, self.isSheetLeaving else { return }
                self.isSheetLeaving = false
                self.sheet = nil
            }
            return
        }
        if let current = self.sheet, current.isFullScreen, sheet.isFullScreen, !isSheetLeaving {
            guard !isSheetHandingOff else { return }
            isSheetHandingOff = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.sheetDropMilliseconds)) { [weak self] in
                guard let self, self.isSheetHandingOff else { return }
                self.isSheetHandingOff = false
                self.isHandedOff = true
                self.sheet = sheet
            }
            return
        }
        isSheetLeaving = false
        isHandedOff = false
        withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
            self.sheet = sheet
        }
    }

    func go(_ route: Route, from tile: CGRect? = nil) {
        guard route != self.route, !isChromeLeaving else { return }
        guard route.isPage != self.route.isPage else {
            switchRoute(route, from: tile)
            return
        }
        isChromeLeaving = true
        isPageChromeShown = false
        DispatchQueue.main.async { [weak self] in
            self?.switchRoute(route, from: tile)
            self?.isChromeLeaving = false
        }
    }

    func toggleExplorer() {
        isExplorerOpen.toggle()
    }

    func closeExplorer() {
        isExplorerOpen = false
    }

    func openExplorer(moving target: TileTarget) {
        explorerMove = target
        isExplorerOpen = true
    }

    func showPageChrome(_ shown: Bool) {
        guard route.isPage else { return }
        isPageChromeShown = shown
    }

    private func switchRoute(_ route: Route, from tile: CGRect?) {
        openingTile = tile
        isReturningFromPage = self.route.isPage && !route.isPage
        if case .page(let notebookId, let pageId) = route {
            lastPage = (notebookId, pageId)
        }
        withAnimation(Motion.powerTwoOut(Motion.sectionEnterMilliseconds)) {
            self.route = route
            query = ""
        }
    }
}

private struct ScreenInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

struct ChromeLayout: Equatable {
    var bottom: CGFloat = 0
    var back: CGRect = .zero
    var frames: [String: CGRect] = [:]
}

private struct ChromeLayoutKey: EnvironmentKey {
    static let defaultValue = ChromeLayout()
}

private struct WindowPushKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    var screenInsets: EdgeInsets {
        get { self[ScreenInsetsKey.self] }
        set { self[ScreenInsetsKey.self] = newValue }
    }

    var chromeLayout: ChromeLayout {
        get { self[ChromeLayoutKey.self] }
        set { self[ChromeLayoutKey.self] = newValue }
    }

    var windowPush: CGSize {
        get { self[WindowPushKey.self] }
        set { self[WindowPushKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: Library
    @StateObject private var navigator = Navigator()
    @StateObject private var menu = MenuController()
    @StateObject private var preferences = Preferences.shared
    @StateObject private var transferBar = TransferBar()
    @State private var chromeLayout = ChromeLayout()
    @State private var navCovers: [CGRect] = []
    @Environment(\.scenePhase) private var scenePhase

    private var titleCutouts: [CGRect] {
        guard navigator.route.isPage, let title = chromeLayout.frames["title"] else { return [] }
        return navCovers.filter { $0.intersects(title) }.map { $0.offsetBy(dx: -title.minX, dy: -title.minY) }
    }

    private var coveredChrome: Set<String> {
        guard navigator.route.isPage else { return [] }
        return Set(chromeLayout.frames.filter { _, frame in navCovers.contains { $0.intersects(frame) } }.keys)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.ground
                if preferences.showsAsciiBackground {
                    AsciiBackground(color: preferences.asciiBackgroundColor, opacity: preferences.asciiBackgroundOpacity, isMoving: preferences.isAsciiBackgroundMoving && (preferences.doesAsciiBackgroundMoveInCanvas || !navigator.route.isPage))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                screen
                    .id(screenIdentity)
                    .transition(isFlight ? .flight : navigator.isReturningFromPage ? .returning : .section)
                    .environment(\.chromeLayout, chromeLayout)
                    .environment(\.windowPush, pushOffset(fullSize(proxy)))
                    .onPreferenceChange(NavCoverKey.self) { navCovers = $0 }
                    .offset(pushOffset(fullSize(proxy)))
                VStack {
                    TopBar(titleCutouts: titleCutouts, coveredChrome: coveredChrome)
                        .onPreferenceChange(TopBarHeightKey.self) { chromeLayout.bottom = $0 - pushOffset(fullSize(proxy)).height }
                        .onPreferenceChange(BackButtonFrameKey.self) { chromeLayout.back = $0 }
                        .onPreferenceChange(ChromeFramesKey.self) { chromeLayout.frames = $0 }
                    Spacer(minLength: 0)
                }
                .offset(y: pushOffset(fullSize(proxy)).height)
                .zIndex(navigator.sheet?.isSeeThrough == true ? 3 : 1)
                ExplorerOverlay(screenSize: fullSize(proxy))
                    .zIndex(1)
                MenuOverlay(controller: menu)
                    .zIndex(1)
                if let sheet = navigator.sheet {
                    SheetHost(request: sheet)
                        .id(sheet.id)
                        .transition(.identity)
                        .zIndex(2)
                }
            }
            .ignoresSafeArea()
            .environment(\.screenInsets, proxy.safeAreaInsets)
            .onAppear { menu.screenSize = fullSize(proxy) }
            .onChange(of: proxy.size) { _, _ in menu.screenSize = fullSize(proxy) }
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(false)
        .defersSystemGestures(on: navigator.route.isPage ? .all : [])
        .environmentObject(navigator)
        .environmentObject(menu)
        .environmentObject(preferences)
        .environmentObject(transferBar)
        .preferredColorScheme(.dark)
        .onAppear {
            ImportImages.shared.assetURL = { [library] asset in library.assetURL(asset) }
            library.adoptDeviceGroups(preferences.takeDeviceGroups())
            restoreLastRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                library.sync.appBecameActive()
            case .background:
                library.finishText()
                SessionMemory.flush()
                library.sync.appEnteredBackground()
            default:
                break
            }
        }
        .onChange(of: navigator.route) { _, route in
            SessionMemory.rememberRoute(route)
            SessionMemory.flush()
            menu.dismiss()
            library.finishText()
            library.sync.flush()
        }
    }

    private func restoreLastRoute() {
        guard navigator.route == .library, let route = SessionMemory.lastRoute() else { return }
        switch route {
        case .library:
            break
        case .notebook(let notebookId):
            if library.notebook(notebookId) != nil {
                navigator.go(.notebook(notebookId))
            }
        case .page(_, let pageId):
            if let page = library.page(pageId), library.notebook(page.notebook) != nil {
                navigator.go(.page(notebookId: page.notebook, pageId: page.id))
            }
        }
    }

    private func pushOffset(_ size: CGSize) -> CGSize {
        switch navigator.sheet?.pushEdge {
        case .top: return CGSize(width: 0, height: navigator.windowPush * size.height)
        case .leading: return CGSize(width: navigator.windowPush * size.width, height: 0)
        default: return .zero
        }
    }

    private func fullSize(_ proxy: GeometryProxy) -> CGSize {
        CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing, height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
    }

    private var screenIdentity: String {
        switch navigator.route {
        case .library, .notebook:
            return "folders"
        case .page(_, let pageId):
            return "page-\(pageId)"
        }
    }

    private var isFlight: Bool {
        if case .page = navigator.route {
            return navigator.openingTile != nil
        }
        return false
    }

    @ViewBuilder
    private var screen: some View {
        switch navigator.route {
        case .library, .notebook:
            GridScreen(notebookId: navigator.route.folderId)
        case .page(let notebookId, let pageId):
            PageScreen(notebookId: notebookId, pageId: pageId)
        }
    }
}

struct BackButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct TopBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChromeFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

extension View {
    func reportsChrome(_ key: String, isActive: Bool = true) -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .preference(key: ChromeFramesKey.self, value: isActive ? [key: proxy.frame(in: .global)] : [:])
                .preference(key: TopBarHeightKey.self, value: isActive ? proxy.frame(in: .global).maxY : 0)
        })
    }
}

struct RoundIconButton: View {
    let glyph: String
    var color: Color = Palette.textBody
    var label: String?
    var isTinted = false
    var isEnabled = true
    let action: () -> Void

    private static var morph: Animation {
        Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2)
    }

    var body: some View {
        HoldableButton(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    GlyphView(name: glyph, color: color)
                        .id(glyph)
                        .transition(.pop)
                }
                if let label {
                    Text(label)
                        .font(Typography.monoBold(13))
                        .foregroundColor(color)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .transition(.pop)
                }
            }
            .padding(.horizontal, label == nil ? 0 : 16)
            .frame(minWidth: TopBar.controlHeight, minHeight: TopBar.controlHeight)
            .background(Capsule().fill(isTinted ? color.opacity(0.14) : Palette.panel).background(Capsule().fill(Palette.panelSolid)))
            .overlay(Capsule().stroke(isTinted ? color.opacity(0.55) : Palette.border, lineWidth: isTinted ? 1.5 : 1))
            .animation(Self.morph, value: label == nil)
            .animation(Self.morph, value: isTinted)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
    }
}

private struct ControlFace {
    var glyph: String
    var color: Color = Palette.textBody
    var label: String?
    var isTinted = false
    var isEnabled = true
    var title: String
    var action: () -> Void
}

struct TopBar: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var transferBar: TransferBar
    @Environment(\.screenInsets) private var insets
    @State private var headFolderId: String?
    @State private var pageTitleWidth: CGFloat = 0
    var titleCutouts: [CGRect] = []
    var coveredChrome: Set<String> = []

    static let controlHeight: CGFloat = 48

    private static var bareTitleSize: CGFloat { 15 }
    private static var topGap: CGFloat { 6 }
    private static let createdFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yy"
        return formatter
    }()

    private var isPage: Bool {
        navigator.route.isPage
    }

    private var folderId: String? {
        navigator.route.folderId
    }

    private var isHeadShown: Bool {
        !isPage && folderId != nil
    }

    private var isTransferring: Bool {
        navigator.sheet?.isSeeThrough == true && !navigator.isSheetLeaving
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 14) {
                if !isTransferring {
                    control(ControlFace(glyph: "explorer", color: navigator.isExplorerOpen ? Palette.accent : Palette.textBody, isTinted: navigator.isExplorerOpen, title: "Explorer") { navigator.toggleExplorer() })
                        .keyboardShortcut("e", modifiers: .command)
                        .transition(.popTogether)
                }
                if isPage && !isTransferring {
                    control(ControlFace(glyph: "view_all", color: Palette.view, title: "View all", action: openViewAll))
                        .transition(.popTogether)
                }
            }
            .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isTransferring)
            .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isPage)
            .allowsHitTesting(!coveredChrome.contains("leading"))
            .reportsChrome("leading")
            ZStack(alignment: .topLeading) {
                folderLine
                    .allowsHitTesting(isHeadShown)
                    .reportsChrome("title", isActive: isHeadShown)
                pageTitles
                    .allowsHitTesting(isPage && !isTransferring && !isPageTitleCovered)
                    .reportsChrome("title", isActive: isPage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                ZStack(alignment: .trailing) {
                    SearchField(text: $navigator.query, isShown: !isPage)
                        .reportsChrome("search", isActive: !isPage)
                    if isPage, let page = navigator.lastPage, library.isReadOnly(page.pageId) {
                        MicroLabel(text: "Read only", color: Palette.destructive)
                            .transition(.popTogether)
                    }
                }
                HStack(spacing: 14) {
                    if isTransferring {
                        transferExtras
                    }
                    control(settingsFace)
                    if isPage {
                        control(undoFace)
                            .transition(.popTogether)
                    }
                    if isPage && !isTransferring {
                        control(redoFace)
                            .transition(.popTogether)
                    }
                    if folderId != nil {
                        control(backFace)
                            .background(GeometryReader { proxy in Color.clear.preference(key: BackButtonFrameKey.self, value: proxy.frame(in: .global)) })
                            .transition(.popTogether)
                    }
                }
                .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isTransferring)
                .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: transferBar.state)
                .allowsHitTesting(!coveredChrome.contains("controls"))
                .reportsChrome("controls")
            }
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.top, Self.topGap + insets.top)
        .onAppear { headFolderId = folderId }
        .onChange(of: folderId) { _, next in
            if let next {
                headFolderId = next
            }
        }
    }

    private var isPageTitleCovered: Bool {
        let backdrop = Tokens.shared.title
        let shown = CGRect(x: 0, y: 0, width: pageTitleWidth + CGFloat(backdrop.backdropPaddingHorizontal) * 2, height: Self.controlHeight + CGFloat(backdrop.backdropPaddingVertical) * 2)
        return titleCutouts.contains { $0.intersects(shown) }
    }

    private func control(_ face: ControlFace) -> some View {
        RoundIconButton(glyph: face.glyph, color: face.color, label: face.label, isTinted: face.isTinted, isEnabled: face.isEnabled, action: face.action)
            .accessibilityLabel(face.title)
    }

    private var settingsFace: ControlFace {
        guard isTransferring else {
            return ControlFace(glyph: "gear", title: "Settings") { navigator.show(.settings) }
        }
        return transferFace(.import)
    }

    private var undoFace: ControlFace {
        guard isTransferring else {
            let pageId = navigator.lastPage?.pageId
            return ControlFace(glyph: "undo", color: Palette.undo, isEnabled: pageId.map { library.canUndo($0) } ?? false, title: "Undo") {
                if let pageId {
                    library.undo(pageId)
                }
            }
        }
        return transferFace(.export)
    }

    private var redoFace: ControlFace {
        let pageId = navigator.lastPage?.pageId
        return ControlFace(glyph: "redo", color: Palette.redo, isEnabled: pageId.map { library.canRedo($0) } ?? false, title: "Redo") {
            if let pageId {
                library.redo(pageId)
            }
        }
    }

    private var backFace: ControlFace {
        guard isTransferring else {
            return ControlFace(glyph: "back", color: Palette.navigation, title: "Back", action: goBack)
        }
        let title = transferBar.state.mode == .view ? "Back to the note" : "Back to view all"
        return ControlFace(glyph: "back", color: Palette.navigation, title: title) { transferBar.perform(.back) }
    }

    private func transferFace(_ target: TransferMode) -> ControlFace {
        let state = transferBar.state
        let isCurrent = state.mode == target
        let isImport = target == .import
        let title = isImport ? "Import" : "Export"
        let isEnabled = (!isImport || state.isEditable) && (!isCurrent || state.isSubmittable)
        return ControlFace(glyph: isImport ? "import" : "export", color: isImport ? Palette.importAsset : Palette.edit, label: isCurrent ? state.count : nil, isTinted: isCurrent, isEnabled: isEnabled, title: isCurrent ? "\(title) \(state.count ?? "") pages" : title) {
            transferBar.perform(isCurrent ? .submit : .pick(target))
        }
    }

    @ViewBuilder
    private var transferExtras: some View {
        let state = transferBar.state
        if state.mode == .view {
            if state.isEditable {
                if state.isSelecting {
                    control(ControlFace(glyph: "trash", color: Palette.destructive, isTinted: true, isEnabled: state.hasSelection, title: "Clear selected pages") { transferBar.perform(.clear) })
                        .transition(.popTogether)
                }
                control(ControlFace(glyph: "check", color: state.isSelecting ? Palette.create : Palette.textBody, isTinted: state.isSelecting, title: state.isSelecting ? "Stop selecting" : "Select pages") { transferBar.perform(.select) })
                    .transition(.popTogether)
            }
        } else {
            control(ControlFace(glyph: "invert", color: Palette.importAsset, isTinted: state.isInvertOn, isEnabled: state.isInvertible, title: state.isInvertOn ? "Show PDF pages as they are" : "Invert PDF pages") { transferBar.perform(.invert) })
                .transition(.popTogether)
        }
    }

    private func openViewAll() {
        guard case .page(_, let pageId) = navigator.route else { return }
        navigator.show(.transfer(pageId: pageId, mode: .view))
    }

    private func goBack() {
        switch navigator.route {
        case .library:
            break
        case .notebook(let notebookId):
            navigator.go(library.parent(of: notebookId).map(Route.notebook) ?? .library)
        case .page(let notebookId, _):
            navigator.go(.notebook(notebookId))
        }
    }

    private var folderLine: some View {
        let isShown = isHeadShown
        let stagger = Motion.chromeStaggerMilliseconds
        let backdrop = Tokens.shared.title
        let segments = headFolderId.map { library.depth(of: $0) } ?? []
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            FolderPathLine(segments: segments) { notebookId in
                navigator.go(.notebook(notebookId))
            } title: { title in
                InlineTitle(title: title, size: Self.bareTitleSize, isSweeping: false) { title in
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let headFolderId else { return }
                    library.updateNotebook(headFolderId) { $0.title = title }
                }
            }
            .labelReveal(isShown)
            Text(headFolderId.map { library.folderSummary($0) } ?? "")
                .font(Typography.mono(10))
                .foregroundColor(Palette.textMuted)
                .lineLimit(1)
                .fixedSize()
                .labelReveal(isShown, delay: stagger * 2)
        }
        .id(headFolderId.map { library.depthText(of: $0) } ?? "")
        .padding(.horizontal, CGFloat(backdrop.backdropPaddingHorizontal))
        .padding(.vertical, CGFloat(backdrop.backdropPaddingVertical))
        .background(
            RoundedRectangle(cornerRadius: CGFloat(backdrop.backdropRadius), style: .continuous)
                .fill(Color.black.opacity(isShown ? backdrop.backdropOpacity : 0))
                .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isShown)
        )
        .opacity(isShown ? 1 : 0)
        .animation(Motion.powerTwoIn(Motion.navigationLeaveElementMilliseconds), value: isShown)
    }

    private var pageTitles: some View {
        let isShown = isPage && navigator.isPageChromeShown
        let stagger = Motion.chromeStaggerMilliseconds
        let page = navigator.lastPage
        let note = page.flatMap { library.page($0.pageId) }
        let backdrop = Tokens.shared.title
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            MicroLabel(text: page.flatMap { library.notebook($0.notebookId)?.title } ?? "Folder")
                .fixedSize()
                .labelReveal(isShown)
            InlineTitle(title: note.map { library.noteTitle($0) } ?? "Note", size: Self.bareTitleSize, isSweeping: false) { title in
                guard let page else { return }
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                library.updatePage(page.pageId) { $0.title = trimmed.isEmpty ? nil : title }
            }
            .labelReveal(isShown, delay: stagger)
            if let created = page.flatMap({ Identifier.creationDate(of: $0.pageId) }) {
                Text(Self.createdFormat.string(from: created))
                    .font(Typography.mono(10))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize()
                    .labelReveal(isShown, delay: stagger * 2)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { pageTitleWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in pageTitleWidth = width }
        })
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CGFloat(backdrop.backdropPaddingHorizontal))
        .padding(.vertical, CGFloat(backdrop.backdropPaddingVertical))
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: CGFloat(backdrop.backdropRadius), style: .continuous)
                .fill(Color.black.opacity(isShown ? backdrop.backdropOpacity : 0))
                .frame(width: pageTitleWidth + CGFloat(backdrop.backdropPaddingHorizontal) * 2)
                .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isShown)
        }
        .mask(CutoutShape(holes: titleCutouts).fill(style: FillStyle(eoFill: true)))
        .contentShape(CutoutShape(holes: titleCutouts), eoFill: true)
    }
}

struct FolderPathLine<Title: View>: View {
    let segments: [DepthSegment]
    let onSelect: (String) -> Void
    @ViewBuilder let title: (String) -> Title

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.dropLast()), id: \.id) { segment in
                if let group = segment.group {
                    MicroLabel(text: "\(group) - ", color: Palette.textFaint)
                        .fixedSize()
                }
                Button {
                    onSelect(segment.id)
                } label: {
                    MicroLabel(text: segment.title)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                MicroLabel(text: "/", color: Palette.textFaint)
                    .padding(.horizontal, 6)
                    .fixedSize()
            }
            if let current = segments.last {
                if let group = current.group {
                    MicroLabel(text: "\(group) - ", color: Palette.textFaint)
                        .fixedSize()
                        .padding(.trailing, 4)
                }
                title(current.title)
            }
        }
    }
}

struct CutoutShape: Shape {
    let holes: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes {
            let radius = min(hole.width, hole.height) / 2
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

struct InlineTitle: View {
    let title: String
    var size: CGFloat = 34
    var isSweeping = true
    var lines = 1
    var minimumScale: CGFloat = 1
    var holdsWidth = false
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $text, axis: .vertical)
                .font(Typography.heading(size))
                .foregroundColor(Palette.textBright)
                .tint(Palette.accent)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.done)
                .lineLimit(1...max(1, lines))
                .onSubmit { isFocused = false }
                .onChange(of: text) { _, next in
                    guard next.contains(where: \.isNewline) else { return }
                    text = next.filter { !$0.isNewline }
                    isFocused = false
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        finish()
                    }
                }
                .onAppear { isFocused = true }
                .onDisappear(perform: finish)
        } else {
            SweepTitle(text: title, size: size, isSweeping: isSweeping, lines: lines, minimumScale: minimumScale, holdsWidth: holdsWidth)
                .contentShape(Rectangle())
                .onTapGesture {
                    text = title
                    isEditing = true
                }
        }
    }

    private func finish() {
        guard isEditing else { return }
        isEditing = false
        if text != title {
            onRename(text)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var isShown = true
    @FocusState private var isFocused: Bool
    @StateObject private var motion = PillMotion()
    @State private var typedCount = 0

    private static let prompt = "Search"

    var body: some View {
        HStack(spacing: 10) {
            GlyphView(name: "search", color: Palette.textMuted, size: 18)
                .revealedElement()
            TextField("", text: $text, prompt: Text(String(Self.prompt.prefix(typedCount))).foregroundColor(Palette.textMuted))
                .opacity(motion.areElementsShown ? 1 : 0)
                .font(Typography.mono(14))
                .foregroundColor(Palette.textPrimary)
                .tint(Palette.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    GlyphView(name: "close", color: Palette.textMuted, size: 16)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(PressableStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .environment(\.isElementRevealed, motion.areElementsShown)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(width: 260, height: TopBar.controlHeight)
        .background(PillShell(scale: motion.shellScale, spread: motion.shellSpread, isWide: true, stroke: isFocused ? Palette.accent : Palette.borderControl))
        .allowsHitTesting(motion.areElementsShown)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: text.isEmpty)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isFocused)
        .onAppear {
            if isShown {
                motion.enter()
            }
        }
        .onChange(of: isShown) { _, shown in
            if shown {
                motion.enter()
            } else {
                isFocused = false
                motion.leave()
            }
        }
        .onChange(of: motion.areElementsShown) { _, shown in
            guard shown, typedCount == 0 else { return }
            Task { @MainActor in
                for count in 1...Self.prompt.count {
                    try? await Task.sleep(nanoseconds: UInt64(Motion.typeMilliseconds) * 1_000_000)
                    typedCount = count
                }
            }
        }
    }
}
