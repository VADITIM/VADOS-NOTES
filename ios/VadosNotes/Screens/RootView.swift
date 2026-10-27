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
    case settings

    var id: String {
        switch self {
        case .newFolder(let parentId): return "new-folder-\(parentId ?? "root")"
        case .renameFolder(let notebookId): return "rename-folder-\(notebookId)"
        case .renameNote(let pageId): return "rename-note-\(pageId)"
        case .appearance(let target): return "appearance-\(target)"
        case .move(let target): return "move-\(target)"
        case .newNote(let notebookId): return "new-note-\(notebookId)"
        case .settings: return "settings"
        }
    }
}

@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var route: Route = .library
    @Published private(set) var sheet: SheetRequest?

    func show(_ sheet: SheetRequest?) {
        withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
            self.sheet = sheet
        }
    }

    func go(_ route: Route) {
        guard route != self.route else { return }
        withAnimation(Motion.powerTwoOut(Motion.sectionEnterMilliseconds)) {
            self.route = route
        }
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
                Palette.ground.ignoresSafeArea()
                screen
                    .id(navigator.route)
                    .transition(.section)
                MenuOverlay(controller: menu)
                if let sheet = navigator.sheet {
                    SheetHost(request: sheet)
                        .transition(.opacity.animation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)))
                        .zIndex(2)
                }
            }
            .onAppear { menu.screenSize = proxy.size }
            .onChange(of: proxy.size) { _, size in menu.screenSize = size }
        }
        .ignoresSafeArea(.keyboard)
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

struct TopBar<Trailing: View, Below: View>: View {
    let title: String
    var label: String?
    var onBack: (() -> Void)?
    var onTitle: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var below: () -> Below

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                if let onBack {
                    HoldableButton(action: onBack) {
                        GlyphView(name: "back", color: Palette.navigation)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Palette.panel))
                            .overlay(Circle().stroke(Palette.border, lineWidth: 1))
                    }
                    .background(GeometryReader { proxy in Color.clear.preference(key: BackButtonFrameKey.self, value: proxy.frame(in: .global)) })
                }
                titles
                Spacer(minLength: 12)
                HStack(spacing: 14) {
                    trailing()
                }
            }
            HStack(spacing: 10) {
                below()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .background(GeometryReader { proxy in Color.clear.preference(key: TopBarHeightKey.self, value: proxy.frame(in: .global).maxY) })
    }

    @ViewBuilder
    private var titles: some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            if let label {
                MicroLabel(text: label)
            }
            SweepTitle(text: title)
        }
        .padding(.horizontal, 20)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Palette.border, lineWidth: 1))
        if let onTitle {
            HoldableButton(pressedScale: 0.97, action: onTitle) {
                content
            }
        } else {
            content
        }
    }
}

extension TopBar where Below == EmptyView {
    init(title: String, label: String? = nil, onBack: (() -> Void)? = nil, onTitle: (() -> Void)? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.label = label
        self.onBack = onBack
        self.onTitle = onTitle
        self.trailing = trailing
        self.below = { EmptyView() }
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
