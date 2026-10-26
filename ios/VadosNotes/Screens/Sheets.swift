import NotesCore
import SwiftUI

struct SheetHost: View {
    let request: SheetRequest

    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { navigator.show(nil) }
            Group {
                switch request {
                case .newNotebook:
                    NameSheet(heading: "New notebook", initial: "", confirmTitle: "Create", confirmColor: Palette.create) { title in
                        NameSheet.Action.create(title)
                    }
                case .rename(let notebookId, let title):
                    NameSheet(heading: "Rename", initial: title, confirmTitle: "Rename", confirmColor: Palette.edit) { newTitle in
                        NameSheet.Action.rename(notebookId, newTitle)
                    }
                case .sync:
                    SyncSheet()
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .transition(.overlay)
        }
    }
}

struct SheetPanel<Content: View>: View {
    let heading: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MicroLabel(text: heading)
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Squircle.sheet.fill(Palette.panelSolid))
        .overlay(Squircle.sheet.stroke(Palette.borderStrong, lineWidth: 1))
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typography.mono(16))
            .foregroundColor(Palette.textPrimary)
            .tint(Palette.accent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Squircle.slot.fill(Palette.sunkenDeep))
            .overlay(Squircle.slot.stroke(Palette.borderControl, lineWidth: 1))
    }
}

struct SlabButton: View {
    let title: String
    let color: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Typography.heading(15))
                .tracking(1.5)
                .foregroundColor(Palette.ground)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Squircle.slot.fill(color))
        }
        .buttonStyle(PressableStyle(pressedScale: 0.97))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
    }
}

struct NameSheet: View {
    enum Action {
        case create(String)
        case rename(String, String)
    }

    let heading: String
    let initial: String
    let confirmTitle: String
    let confirmColor: Color
    let makeAction: (String) -> Action

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @State private var title = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetPanel(heading: heading) {
            TextField("", text: $title, prompt: Text("Title").foregroundColor(Palette.textFaint))
                .modifier(FieldStyle())
                .textInputAutocapitalization(.sentences)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(confirm)
            SlabButton(title: confirmTitle, color: confirmColor, isEnabled: !trimmed.isEmpty, action: confirm)
        }
        .onAppear {
            title = initial
            isFocused = true
        }
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        switch makeAction(trimmed) {
        case .create(let name):
            let notebook = library.createNotebook(title: name)
            navigator.show(nil)
            navigator.go(.notebook(notebook.id))
        case .rename(let notebookId, let name):
            library.rename(notebookId, to: name)
            navigator.show(nil)
        }
    }
}

struct SyncSheet: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @State private var owner = ""
    @State private var repository = ""
    @State private var branch = "main"
    @State private var token = ""
    @State private var hasStoredToken = false

    var body: some View {
        SheetPanel(heading: "Sync with GitHub") {
            HStack(spacing: 10) {
                TextField("", text: $owner, prompt: Text("Owner").foregroundColor(Palette.textFaint))
                    .modifier(FieldStyle())
                Text("/")
                    .font(Typography.mono(18))
                    .foregroundColor(Palette.textFaint)
                TextField("", text: $repository, prompt: Text("Repository").foregroundColor(Palette.textFaint))
                    .modifier(FieldStyle())
            }
            TextField("", text: $branch, prompt: Text("Branch").foregroundColor(Palette.textFaint))
                .modifier(FieldStyle())
            SecureField("", text: $token, prompt: Text(hasStoredToken ? "Token stored in Keychain" : "Fine-grained token").foregroundColor(Palette.textFaint))
                .modifier(FieldStyle())
            HStack {
                MicroLabel(text: library.sync.status.label, color: Palette.textMuted)
                Spacer()
                MicroLabel(text: "\(library.store.journal.entries.count) queued")
            }
            if case .failed(let message) = library.sync.status {
                Text(message)
                    .font(Typography.mono(11))
                    .foregroundColor(Palette.destructive)
                    .lineLimit(3)
            }
            if !library.store.blockedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(library.store.blockedPaths.keys.sorted(), id: \.self) { path in
                        MicroLabel(text: "\(library.store.blockedPaths[path]?.rawValue ?? "") · \(path)", color: Palette.destructive)
                    }
                }
            }
            SlabButton(title: "Save and sync", color: Palette.create, isEnabled: !owner.isEmpty && !repository.isEmpty && !branch.isEmpty) {
                let settings = SyncSettings(
                    owner: owner.trimmingCharacters(in: .whitespaces),
                    repository: repository.trimmingCharacters(in: .whitespaces),
                    branch: branch.trimmingCharacters(in: .whitespaces)
                )
                library.sync.configure(settings, token: token.isEmpty ? nil : token)
                navigator.show(nil)
            }
        }
        .onAppear {
            owner = library.sync.settings.owner
            repository = library.sync.settings.repository
            branch = library.sync.settings.branch
            hasStoredToken = Keychain.readToken() != nil
        }
    }
}
