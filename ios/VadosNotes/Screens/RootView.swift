import NotesCore
import SwiftUI

enum Route: Hashable {
    case library
    case notebook(String)
    case page(notebookId: String, pageId: String)
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
}

@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var route: Route = .library
    @Published private(set) var sheet: SheetRequest?
    var openingTile: CGRect?

    func show(_ sheet: SheetRequest?) {
        withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
            self.sheet = sheet
        }
    }

    func go(_ route: Route, from tile: CGRect? = nil) {
        guard route != self.route else { return }
        openingTile = tile
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
                screen
                    .id(screenIdentity)
                    .transition(isFlight ? .flight : .section)
                MenuOverlay(controller: menu)
                if let sheet = navigator.sheet {
                    SheetHost(request: sheet)
                        .transition(.opacity.animation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)))
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
        RoundIconButton(glyph: "settings", action: { navigator.show(.settings) })
    }
}

struct TopBar<Trailing: View>: View {
    let title: String
    var label: String?
    var detail: String?
    var onBack: (() -> Void)?
    var onRename: ((String) -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.screenInsets) private var insets

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            titles
                .chromeFrame("title")
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                trailing()
                if let onBack {
                    HoldableButton(action: onBack) {
                        GlyphView(name: "back", color: Palette.navigation)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Palette.panel))
                            .overlay(Circle().stroke(Palette.border, lineWidth: 1))
                    }
                    .background(GeometryReader { proxy in Color.clear.preference(key: BackButtonFrameKey.self, value: proxy.frame(in: .global)) })
                    .transition(.popTogether)
                }
                SettingsButton()
            }
            .chromeFrame("controls")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16 + insets.top)
        .background(GeometryReader { proxy in Color.clear.preference(key: TopBarHeightKey.self, value: proxy.frame(in: .global).maxY) })
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
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private static let size: CGFloat = 34

    var body: some View {
        if isEditing {
            TextField("", text: $text)
                .font(Typography.heading(Self.size))
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
            SweepTitle(text: title, size: Self.size)
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
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            GlyphView(name: "search", color: Palette.textMuted, size: 18)
            TextField("", text: $text, prompt: Text("Search").foregroundColor(Palette.textMuted))
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
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(width: 260, height: 48)
        .background(Capsule().fill(Palette.panel))
        .overlay(Capsule().stroke(isFocused ? Palette.accent : Palette.borderControl, lineWidth: 1))
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: text.isEmpty)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isFocused)
    }
}
