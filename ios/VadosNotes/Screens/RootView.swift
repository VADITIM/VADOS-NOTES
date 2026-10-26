import SwiftUI

enum Route: Hashable {
    case library
    case notebook(String)
    case page(notebookId: String, pageId: String)
}

enum SheetRequest: Identifiable, Equatable {
    case newNotebook
    case rename(notebookId: String, title: String)
    case sync

    var id: String {
        switch self {
        case .newNotebook: return "new"
        case .rename(let notebookId, _): return "rename-\(notebookId)"
        case .sync: return "sync"
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
        .preferredColorScheme(.dark)
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
            LibraryScreen()
        case .notebook(let notebookId):
            NotebookScreen(notebookId: notebookId)
        case .page(let notebookId, let pageId):
            PageScreen(notebookId: notebookId, pageId: pageId)
        }
    }
}

struct TopBar<Trailing: View>: View {
    let title: String
    var label: String?
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let onBack {
                HoldableButton(action: onBack) {
                    GlyphView(glyph: .back, color: Palette.navigation)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Palette.panelSolid))
                        .overlay(Circle().stroke(Palette.border, lineWidth: 1))
                }
                .transition(.pop)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let label {
                    MicroLabel(text: label)
                }
                SweepTitle(text: title)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }
}

struct SyncBadge: View {
    @ObservedObject var sync: SyncCoordinator
    @EnvironmentObject private var navigator: Navigator

    private var color: Color {
        switch sync.status {
        case .synced: return Palette.textLabel
        case .syncing: return Palette.accent
        case .paused, .failed: return Palette.destructive
        case .offline, .retrying, .notConnected: return Palette.textMuted
        }
    }

    var body: some View {
        HoldableButton(action: { navigator.show(.sync) }) {
            HStack(spacing: 8) {
                GlyphView(glyph: .sync, color: color, size: 16)
                MicroLabel(text: sync.blockedCount > 0 ? "\(sync.status.label) · \(sync.blockedCount) blocked" : sync.status.label, color: color)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(Palette.panelSolid))
            .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        }
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: sync.status)
    }
}
