import NotesCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SheetHost: View {
    let request: SheetRequest

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.screenInsets) private var insets
    @State private var isShown = false
    @State private var isRaised = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0

    private var isBackdropShown: Bool {
        request.isNaming ? isRaised : isShown
    }

    private var keyboardLift: CGFloat {
        max(keyboardHeight, insets.bottom) + 24
    }

    var body: some View {
        ZStack(alignment: request.isNaming ? .bottom : .top) {
            Color.black.opacity(isBackdropShown ? 0.45 : 0)
                .ignoresSafeArea()
                .onTapGesture { navigator.show(nil) }
            if request == .settings {
                content
                    .padding(.horizontal, 24)
                    .padding(.top, insets.top + 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if isShown {
                if request.isNaming {
                    content
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24)
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { panelHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in panelHeight = height }
                        })
                        .padding(.bottom, keyboardLift)
                        .offset(y: isRaised ? 0 : panelHeight + keyboardLift)
                        .opacity(panelHeight > 0 ? 1 : 0)
                } else {
                    content
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24)
                        .padding(.top, insets.top + 24)
                        .transition(.overlay)
                }
            }
        }
        .onAppear {
            guard !request.isNaming else {
                isShown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.keyboardMilliseconds * 2)) {
                    guard !isRaised, !navigator.isSheetLeaving else { return }
                    withAnimation(Motion.keyboard()) {
                        isRaised = true
                    }
                }
                return
            }
            withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
                isShown = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard request.isNaming, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let seconds = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? Motion.seconds(Motion.keyboardMilliseconds)
            withAnimation(Motion.keyboard(Int(seconds * 1000))) {
                keyboardHeight = max(0, UIScreen.main.bounds.height - frame.minY)
                if !navigator.isSheetLeaving {
                    isRaised = true
                }
            }
        }
        .onChange(of: navigator.isSheetLeaving) { _, isLeaving in
            guard isLeaving else { return }
            guard !request.isNaming else {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                withAnimation(Motion.keyboard()) {
                    isRaised = false
                }
                return
            }
            guard request != .settings else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isShown = false
                }
                return
            }
            withAnimation(Motion.powerTwoIn(Motion.overlayLeaveMilliseconds)) {
                isShown = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch request {
        case .newFolder(let parentId):
            NameSheet(heading: "New folder", initial: "Folder \(library.folders(in: parentId).count + 1)", confirmTitle: "Create", confirmColor: Palette.create, selectsAll: true) { title in
                let notebook = library.createNotebook(title: title, parent: parentId)
                navigator.show(nil)
                navigator.go(.notebook(notebook.id))
            }
        case .renameFolder(let notebookId):
            NameSheet(heading: "Rename folder", initial: library.notebook(notebookId)?.title ?? "", confirmTitle: "Rename", confirmColor: Palette.edit) { title in
                library.updateNotebook(notebookId) { $0.title = title }
                navigator.show(nil)
            }
        case .renameNote(let pageId):
            NameSheet(heading: "Rename note", initial: library.page(pageId).map { library.noteTitle($0) } ?? "", confirmTitle: "Rename", confirmColor: Palette.edit) { title in
                library.updatePage(pageId) { $0.title = title }
                navigator.show(nil)
            }
        case .appearance(let target):
            AppearanceSheet(target: target)
        case .move(let target):
            MoveSheet(target: target)
        case .newNote(let notebookId):
            NewNoteSheet(notebookId: notebookId)
        case .pickGroup(let target, let parentId):
            GroupSheet(target: target, parentId: parentId)
        case .renameGroup(let groupId, let parentId):
            NameSheet(heading: "Rename group", initial: Preferences.shared.groups(in: parentId).first { $0.id == groupId }?.title ?? "", confirmTitle: "Rename", confirmColor: Palette.edit) { title in
                Preferences.shared.renameGroup(groupId, to: title, in: parentId)
                navigator.show(nil)
            }
        case .settings:
            SettingsSheet()
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

struct SelectAllOnFocus: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                guard isActive, let field = notification.object as? UITextField else { return }
                DispatchQueue.main.async {
                    field.selectAll(nil)
                }
            }
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
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
    }
}

struct SegmentOption<Value: Hashable>: Hashable {
    let value: Value
    let title: String
}

struct Segmented<Value: Hashable>: View {
    let options: [SegmentOption<Value>]
    let selected: Value
    let onPick: (Value) -> Void

    @Namespace private var washSpace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Button {
                    onPick(option.value)
                } label: {
                    Text(option.title.uppercased())
                        .font(Typography.mono(12))
                        .tracking(1.5)
                        .foregroundColor(option.value == selected ? Palette.textBright : Palette.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if option.value == selected {
                                Capsule().fill(Palette.pressedWash).matchedGeometryEffect(id: "wash", in: washSpace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(4)
        .frame(height: 46)
        .background(Capsule().fill(Palette.sunkenDeep))
        .overlay(Capsule().stroke(Palette.borderControl, lineWidth: 1))
        .animation(Motion.powerTwoOut(Tokens.shared.motion.durations.navSlide), value: selected)
    }
}

struct NameSheet: View {
    let heading: String
    let initial: String
    let confirmTitle: String
    let confirmColor: Color
    var selectsAll = false
    let confirm: (String) -> Void

    @State private var title = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetPanel(heading: heading) {
            TextField("", text: $title, prompt: Text("Name").foregroundColor(Palette.textFaint))
                .modifier(FieldStyle())
                .textInputAutocapitalization(.sentences)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(submit)
                .modifier(SelectAllOnFocus(isActive: selectsAll))
            SlabButton(title: confirmTitle, color: confirmColor, isEnabled: !trimmed.isEmpty, action: submit)
        }
        .onAppear {
            title = initial
            isFocused = true
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        confirm(trimmed)
    }
}

struct GroupSheet: View {
    let target: TileTarget
    let parentId: String?

    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var preferences: Preferences
    @State private var title = ""
    @FocusState private var isFocused: Bool

    private var memberId: String {
        switch target {
        case .folder(let id), .note(let id): return id
        }
    }

    private var isFolders: Bool {
        if case .folder = target {
            return true
        }
        return false
    }

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let groups = preferences.groups(in: parentId).filter { $0.isFolders == isFolders }
        SheetPanel(heading: "Add to group") {
            if !groups.isEmpty {
                VStack(spacing: 4) {
                    ForEach(groups) { group in
                        Button {
                            preferences.addToGroup(memberId, groupId: group.id, in: parentId)
                            navigator.show(nil)
                        } label: {
                            HStack(spacing: 12) {
                                GlyphView(name: "stack", color: Palette.accent, size: 18)
                                Text(group.title)
                                    .font(Typography.mono(13))
                                    .foregroundColor(Palette.textBright)
                                    .lineLimit(1)
                                Spacer()
                                MicroLabel(text: "\(group.members.count)")
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.sunkenDeep))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            TextField("", text: $title, prompt: Text("New group").foregroundColor(Palette.textFaint))
                .modifier(FieldStyle())
                .textInputAutocapitalization(.sentences)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(create)
            SlabButton(title: "Create group", color: Palette.create, isEnabled: !trimmed.isEmpty, action: create)
        }
        .onAppear {
            isFocused = groups.isEmpty
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        preferences.createGroup(trimmed, isFolders: isFolders, with: memberId, in: parentId)
        navigator.show(nil)
    }
}

struct AppearanceSheet: View {
    let target: TileTarget

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var preferences: Preferences
    @State private var isWheelOpen = false
    @State private var wheelColor: String?
    @State private var wheelWrite: DispatchWorkItem?

    private static let wheelWriteDelay = 0.25

    private var details: (title: String, color: String, icon: String)? {
        switch target {
        case .folder(let id):
            guard let notebook = library.notebook(id) else { return nil }
            let look = Looks.folder(notebook)
            return (notebook.title, look.color, look.icon)
        case .note(let id):
            guard let page = library.page(id) else { return nil }
            let look = Looks.note(page)
            return (library.noteTitle(page), look.color, look.icon)
        }
    }

    private func apply(color: String? = nil, icon: String? = nil) {
        switch target {
        case .folder(let id):
            library.updateNotebook(id) { notebook in
                if let color { notebook.color = color }
                if let icon { notebook.icon = icon }
            }
        case .note(let id):
            library.updatePage(id) { header in
                if let color { header.color = color }
                if let icon { header.icon = icon }
            }
        }
    }

    private func pickFromWheel(_ hex: String) {
        wheelColor = hex
        wheelWrite?.cancel()
        let work = DispatchWorkItem { writeWheelColor() }
        wheelWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wheelWriteDelay, execute: work)
    }

    private func writeWheelColor() {
        wheelWrite?.cancel()
        wheelWrite = nil
        guard let wheelColor else { return }
        self.wheelColor = nil
        apply(color: wheelColor)
    }

    var body: some View {
        let _ = library.revision
        let _ = preferences.revision
        SheetPanel(heading: "Icon & colour") {
            if let details {
                let shownColor = (wheelColor ?? details.color).uppercased()
                let presets = preferences.folderColorPresets
                HStack(spacing: 14) {
                    GlyphView(name: details.icon, color: Color(hex: shownColor), size: 28)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.sunkenDeep))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.borderControl, lineWidth: 1))
                    Text(details.title)
                        .font(Typography.heading(19))
                        .foregroundColor(Palette.textBright)
                        .lineLimit(1)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: SwatchButton.pitch), spacing: 4)], alignment: .leading, spacing: 4) {
                    WheelButton(isOpen: isWheelOpen, orientation: .horizontal) {
                        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                            isWheelOpen.toggle()
                        }
                    }
                    ForEach(presets, id: \.self) { color in
                        SwatchButton(color: Color(hex: color), isSelected: color.uppercased() == shownColor, orientation: .horizontal, onSelect: {
                            wheelColor = nil
                            wheelWrite?.cancel()
                            apply(color: color)
                        }, onRemove: { preferences.removeFolderColorPreset(color) })
                    }
                    GroupEndButton(isCollapsed: false, isEnabled: !presets.map { $0.uppercased() }.contains(shownColor), orientation: .horizontal) {
                        preferences.addFolderColorPreset(shownColor)
                    }
                }
                if isWheelOpen {
                    ColorPanel(color: shownColor, onChange: pickFromWheel)
                        .transition(.popTogether)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                    ForEach(Tokens.shared.folders.icons, id: \.self) { icon in
                        Button {
                            apply(icon: icon)
                        } label: {
                            GlyphView(name: icon, color: icon == details.icon ? Color(hex: shownColor) : Palette.textMuted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.sunkenDeep))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(icon == details.icon ? Color(hex: shownColor) : .clear, lineWidth: 2))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            SlabButton(title: "Done", color: Palette.create) { navigator.show(nil) }
        }
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isWheelOpen)
        .onDisappear(perform: writeWheelColor)
    }
}

struct MoveSheet: View {
    let target: TileTarget

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator

    private struct Row: Identifiable {
        let id: String
        let notebook: Notebook?
        let depth: Int
    }

    private func tree(_ parentId: String?, depth: Int) -> [Row] {
        library.folders(in: parentId).flatMap { folder in
            [Row(id: folder.id, notebook: folder, depth: depth)] + tree(folder.id, depth: depth + 1)
        }
    }

    var body: some View {
        let rows: [Row] = {
            switch target {
            case .folder: return [Row(id: "root", notebook: nil, depth: 0)] + tree(nil, depth: 0)
            case .note: return tree(nil, depth: 0)
            }
        }()
        SheetPanel(heading: "Move to") {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(rows) { row in
                        moveRow(row)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 440)
        }
    }

    private func state(of row: Row) -> (isCurrent: Bool, isEnabled: Bool) {
        switch target {
        case .folder(let id):
            let destination = row.notebook?.id
            let isCurrent = library.parent(of: id) == destination
            return (isCurrent, !isCurrent && library.canMoveNotebook(id, into: destination))
        case .note(let id):
            let isCurrent = library.page(id)?.notebook == row.notebook?.id
            return (isCurrent, !isCurrent && row.notebook != nil)
        }
    }

    private func move(to row: Row) {
        switch target {
        case .folder(let id):
            library.moveNotebook(id, into: row.notebook?.id)
        case .note(let id):
            if let destination = row.notebook?.id {
                library.movePage(id, to: destination)
            }
        }
        navigator.show(nil)
    }

    private func moveRow(_ row: Row) -> some View {
        let rowState = state(of: row)
        let isCurrent = rowState.isCurrent
        let isEnabled = rowState.isEnabled
        let look = Looks.folder(row.notebook)
        return Button {
            move(to: row)
        } label: {
            HStack(spacing: 12) {
                GlyphView(name: row.notebook == nil ? "home" : look.icon, color: row.notebook == nil ? Palette.navigation : Color(hex: look.color), size: 18)
                Text(row.notebook?.title ?? "Folders (top level)")
                    .font(Typography.mono(13))
                    .foregroundColor(Palette.textBright)
                    .lineLimit(1)
                Spacer()
                if isCurrent {
                    MicroLabel(text: "Here")
                }
            }
            .padding(.leading, 16 + CGFloat(row.depth) * 22)
            .padding(.trailing, 16)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.sunkenDeep))
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct NewNoteSheet: View {
    let notebookId: String

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @State private var title = ""
    @State private var isPdf = false
    @State private var document: ImportedDocument?
    @State private var fileName: String?
    @State private var detail = "No file chosen"
    @State private var isFailed = false
    @State private var isPicking = false
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetPanel(heading: "New note") {
            TextField("", text: $title, prompt: Text("Name").foregroundColor(Palette.textFaint))
                .modifier(FieldStyle())
                .textInputAutocapitalization(.sentences)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(create)
                .modifier(SelectAllOnFocus(isActive: true))
            Segmented(options: [SegmentOption(value: false, title: "Blank"), SegmentOption(value: true, title: "PDF")], selected: isPdf) { value in
                isPdf = value
                if value && document == nil {
                    isPicking = true
                }
            }
            if isPdf {
                Button {
                    isPicking = true
                } label: {
                    HStack(spacing: 14) {
                        GlyphView(name: "note_add", color: Palette.importAsset)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fileName ?? "Choose PDF")
                                .font(Typography.monoBold(14))
                                .foregroundColor(Palette.textBright)
                                .lineLimit(1)
                            MicroLabel(text: detail, color: isFailed ? Palette.destructive : Palette.textMuted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Palette.sunkenDeep))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.importAsset.opacity(0.45), lineWidth: 1.5))
                }
                .buttonStyle(PressableStyle())
                .transition(.opacity)
            }
            SlabButton(title: "Create", color: Palette.create, isEnabled: !trimmed.isEmpty && (!isPdf || document != nil), action: create)
        }
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isPdf)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                fileName = url.lastPathComponent
                do {
                    let imported = try ImportImages.importDocument(from: url, into: library)
                    document = imported
                    isFailed = false
                    detail = "\(imported.pages.count) page\(imported.pages.count == 1 ? "" : "s")"
                    if trimmed.isEmpty || trimmed.hasPrefix("Note ") {
                        title = url.deletingPathExtension().lastPathComponent
                    }
                } catch {
                    document = nil
                    isFailed = true
                    detail = "Not a readable PDF"
                }
            case .failure:
                break
            }
        }
        .onAppear {
            title = "Note \(library.pages(in: notebookId).count + 1)"
            isFocused = true
        }
    }

    private func create() {
        guard !trimmed.isEmpty, !isPdf || document != nil else { return }
        let page = library.createPage(in: notebookId, title: trimmed, document: isPdf ? document : nil)
        navigator.show(nil)
        navigator.go(.page(notebookId: notebookId, pageId: page.id))
    }
}

