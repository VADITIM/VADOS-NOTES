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
    private(set) var isReturningFromPage = false
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.chromeLeaveMilliseconds)) { [weak self] in
            self?.switchRoute(route, from: tile)
            self?.isChromeLeaving = false
        }
    }

    private func switchRoute(_ route: Route, from tile: CGRect?) {
        openingTile = tile
        isReturningFromPage = self.route.isPage && !route.isPage
        withAnimation(Motion.powerTwoOut(Motion.sectionEnterMilliseconds)) {
            self.route = route
        }
    }
}

private struct ScreenInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    var screenInsets: EdgeInsets {
        get { self[ScreenInsetsKey.self] }
        set { self[ScreenInsetsKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: Library
    @StateObject private var navigator = Navigator()
    @StateObject private var menu = MenuController()
    @StateObject private var preferences = Preferences.shared
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
                MenuOverlay(controller: menu)
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
        case .library:
            GridScreen(notebookId: nil)
        case .notebook(let notebookId):
            GridScreen(notebookId: notebookId)
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
    func chromeFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: ChromeFramesKey.self, value: [key: proxy.frame(in: .global)]) })
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
                .frame(width: 48, height: 48)
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

struct TopBar<Trailing: View>: View {
    let title: String
    var label: String?
    var detail: String?
    var chromeShown: Bool?
    var onBack: (() -> Void)?
    var onRename: ((String) -> Void)?
    var isBare = false
    var popsTrailing = true
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.screenInsets) private var insets

    private static var bareTitleSize: CGFloat { 15 }
    private static var topGap: CGFloat { 6 }
    private static var titlesDrop: CGFloat { 10 }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if isBare {
                    bareTitles
                } else {
                    titles
                        .modifier(ChromePop(isShown: chromeShown ?? true, order: 0))
                        .padding(.top, Self.titlesDrop)
                }
            }
                .chromeFrame("title")
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                trailing()
                    .modifier(ChromePop(isShown: popsTrailing ? chromeShown ?? true : true, order: 1))
                if let onBack {
                    HoldableButton(action: onBack) {
                        GlyphView(name: "back", color: Palette.navigation)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Palette.panel))
                            .overlay(Circle().stroke(Palette.border, lineWidth: 1))
                    }
                    .background(GeometryReader { proxy in Color.clear.preference(key: BackButtonFrameKey.self, value: proxy.frame(in: .global)) })
                    .modifier(ChromePop(isShown: chromeShown ?? true, order: 2))
                    .transition(.popTogether)
                }
                SettingsButton()
                    .modifier(ChromePop(isShown: chromeShown ?? true, order: 3))
            }
            .chromeFrame("controls")
        }
        .padding(.horizontal, 24)
        .padding(.top, Self.topGap + insets.top)
        .background(GeometryReader { proxy in Color.clear.preference(key: TopBarHeightKey.self, value: proxy.frame(in: .global).maxY) })
    }

    private var bareTitles: some View {
        let isShown = chromeShown ?? true
        let stagger = Motion.chromeStaggerMilliseconds
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let label {
                MicroLabel(text: label)
                    .labelReveal(isShown)
            }
            Group {
                if let onRename {
                    InlineTitle(title: title, size: Self.bareTitleSize, isSweeping: false, onRename: onRename)
                } else {
                    SweepTitle(text: title, size: Self.bareTitleSize, isSweeping: false)
                }
            }
            .labelReveal(isShown, delay: stagger)
            if let detail {
                Text(detail)
                    .font(Typography.mono(10))
                    .foregroundColor(Palette.textMuted)
                    .labelReveal(isShown, delay: stagger * 2)
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                MicroLabel(text: label)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let onRename {
                    InlineTitle(title: title, onRename: onRename)
                } else {
                    SweepTitle(text: title)
                }
                if let detail {
                    Text(detail)
                        .font(Typography.mono(12))
                        .foregroundColor(Palette.textMuted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Palette.border, lineWidth: 1))
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
        .frame(width: 260, height: 48)
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
