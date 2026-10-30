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
        }
    }

    var isNaming: Bool {
        switch self {
        case .newFolder, .renameFolder, .renameNote, .newNote, .pickGroup, .renameGroup: return true
        case .appearance, .move, .settings: return false
        }
    }
}

@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var route: Route = .library
    @Published private(set) var sheet: SheetRequest?
    @Published private(set) var isSheetLeaving = false
    @Published private(set) var isChromeLeaving = false
    @Published private(set) var isPageChromeShown = false
    @Published var query = ""
    private(set) var isReturningFromPage = false
    private(set) var lastPage: (notebookId: String, pageId: String)?
    var openingTile: CGRect?

    func show(_ sheet: SheetRequest?) {
        guard let sheet else {
            guard let current = self.sheet, !isSheetLeaving else { return }
            isSheetLeaving = true
            let leave = current == .settings ? Motion.sheetDropMilliseconds : current.isNaming ? Motion.keyboardMilliseconds : Motion.overlayLeaveMilliseconds
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(leave)) { [weak self] in
                guard let self, self.isSheetLeaving else { return }
                self.isSheetLeaving = false
                self.sheet = nil
            }
            return
        }
        isSheetLeaving = false
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

extension EnvironmentValues {
    var screenInsets: EdgeInsets {
        get { self[ScreenInsetsKey.self] }
        set { self[ScreenInsetsKey.self] = newValue }
    }

    var chromeLayout: ChromeLayout {
        get { self[ChromeLayoutKey.self] }
        set { self[ChromeLayoutKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: Library
    @StateObject private var navigator = Navigator()
    @StateObject private var menu = MenuController()
    @StateObject private var preferences = Preferences.shared
    @State private var chromeLayout = ChromeLayout()
    @Environment(\.scenePhase) private var scenePhase

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
                VStack {
                    TopBar()
                        .onPreferenceChange(TopBarHeightKey.self) { chromeLayout.bottom = $0 }
                        .onPreferenceChange(BackButtonFrameKey.self) { chromeLayout.back = $0 }
                        .onPreferenceChange(ChromeFramesKey.self) { chromeLayout.frames = $0 }
                    Spacer(minLength: 0)
                }
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
        .environmentObject(navigator)
        .environmentObject(menu)
        .environmentObject(preferences)
        .preferredColorScheme(.dark)
        .onAppear {
            ImportImages.shared.assetURL = { [library] asset in library.assetsDirectory.appendingPathComponent("\(asset.replacingOccurrences(of: "sha256:", with: "")).pdf") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                library.sync.appBecameActive()
            case .background:
                library.finishText()
                library.sync.appEnteredBackground()
            default:
                break
            }
        }
        .onChange(of: navigator.route) { _, _ in
            menu.dismiss()
            library.finishText()
            library.sync.flush()
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
    var isTinted = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        HoldableButton(action: action) {
            GlyphView(name: glyph, color: color)
                .frame(width: TopBar.controlHeight, height: TopBar.controlHeight)
                .background(Circle().fill(isTinted ? color.opacity(0.14) : Palette.panel).background(Circle().fill(Palette.panelSolid)))
                .overlay(Circle().stroke(isTinted ? color.opacity(0.55) : Palette.border, lineWidth: isTinted ? 1.5 : 1))
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
    }
}

struct SettingsButton: View {
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        RoundIconButton(glyph: "gear", action: { navigator.show(.settings) })
    }
}

struct TopBar: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.screenInsets) private var insets

    static let controlHeight: CGFloat = 48

    private static var bareTitleSize: CGFloat { 15 }
    private static var folderTitleSize: CGFloat { controlHeight / 2 }
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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .topLeading) {
                folderTitles
                    .modifier(ChromePop(isShown: !isPage, order: 0))
                    .allowsHitTesting(!isPage)
                    .reportsChrome("title", isActive: !isPage)
                pageTitles
                    .allowsHitTesting(isPage)
                    .reportsChrome("title", isActive: isPage)
            }
            Spacer(minLength: 12)
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
                    if folderId != nil {
                        HoldableButton(action: goBack) {
                            GlyphView(name: "back", color: Palette.navigation)
                                .frame(width: TopBar.controlHeight, height: TopBar.controlHeight)
                                .background(Circle().fill(Palette.panel))
                                .overlay(Circle().stroke(Palette.border, lineWidth: 1))
                        }
                        .background(GeometryReader { proxy in Color.clear.preference(key: BackButtonFrameKey.self, value: proxy.frame(in: .global)) })
                        .transition(.popTogether)
                    }
                    SettingsButton()
                }
                .reportsChrome("controls")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, Self.topGap + insets.top)
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

    private var folderTitle: String {
        folderId.flatMap { library.notebook($0)?.title } ?? "Folders"
    }

    private var folderLabel: String {
        guard let folderId else {
            let count = library.folders(in: nil).count
            return "\(count) folder\(count == 1 ? "" : "s")"
        }
        return library.folderSummary(folderId)
    }

    private var folderTitles: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let folderId {
                InlineTitle(title: folderTitle, size: Self.folderTitleSize) { title in
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    library.updateNotebook(folderId) { $0.title = title }
                }
            } else {
                SweepTitle(text: folderTitle, size: Self.folderTitleSize)
            }
            MicroLabel(text: folderLabel)
        }
        .padding(.horizontal, 20)
        .frame(height: Self.controlHeight)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Palette.border, lineWidth: 1))
    }

    private var pageTitles: some View {
        let isShown = isPage && navigator.isPageChromeShown
        let stagger = Motion.chromeStaggerMilliseconds
        let page = navigator.lastPage
        let note = page.flatMap { library.page($0.pageId) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            MicroLabel(text: page.flatMap { library.notebook($0.notebookId)?.title } ?? "Folder")
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
                    .labelReveal(isShown, delay: stagger * 2)
            }
        }
    }
}

struct InlineTitle: View {
    let title: String
    var size: CGFloat = 34
    var isSweeping = true
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $text)
                .font(Typography.heading(size))
                .foregroundColor(Palette.textBright)
                .tint(Palette.accent)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.done)
                .fixedSize()
                .onSubmit { isFocused = false }
                .onChange(of: text) { _, next in onRename(next) }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        isEditing = false
                    }
                }
                .onAppear { isFocused = true }
        } else {
            SweepTitle(text: title, size: size, isSweeping: isSweeping)
                .contentShape(Rectangle())
                .onTapGesture {
                    text = title
                    isEditing = true
                }
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
