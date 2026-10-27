import NotesCore
import SwiftUI

enum Looks {
    static func folder(_ notebook: Notebook?) -> (color: String, icon: String) {
        (notebook?.color ?? Tokens.shared.folders.defaultColor, notebook?.icon ?? Tokens.shared.folders.defaultIcon)
    }

    static func note(_ page: Page?) -> (color: String, icon: String) {
        (page?.color ?? Tokens.shared.palette.textMuted, page?.icon ?? Tokens.shared.folders.noteIcon)
    }
}

private struct TileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

private enum TileKind: String {
    case folder
    case note
}

private struct TileDrag {
    let kind: TileKind
    let id: String
    var location: CGPoint
    let grab: CGSize
    let size: CGSize
    var target: DropTarget?
}

private enum DropTarget: Equatable {
    case into(String)
    case up(String?)
    case before(String)
    case after(String)
}

struct GridScreen: View {
    let notebookId: String?

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController
    @EnvironmentObject private var preferences: Preferences
    @State private var query = ""
    @State private var topBarBottom: CGFloat = 96
    @State private var frames: [String: CGRect] = [:]
    @State private var backFrame: CGRect = .zero
    @State private var drag: TileDrag?
    @State private var arrangedFolders: [String]?
    @State private var arrangedNotes: [String]?

    private let folderColumns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18, alignment: .top)]
    private let noteColumns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 18, alignment: .top)]
    private static let dropEdgeShare: CGFloat = 0.22

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var folders: [Notebook] {
        let items = library.folders(in: notebookId)
        guard let arrangedFolders else { return items }
        return arrangedFolders.compactMap { id in items.first { $0.id == id } }
    }

    private var notes: [Page] {
        guard let notebookId else { return [] }
        let items = library.pages(in: notebookId)
        guard let arrangedNotes else { return items }
        return arrangedNotes.compactMap { id in items.first { $0.id == id } }
    }

    var body: some View {
        let _ = library.revision
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: max(0, topBarBottom - origin.y))
                        if trimmedQuery.isEmpty {
                            browse
                        } else {
                            results
                        }
                    }
                    .padding(.bottom, 48)
                }
                .scrollDisabled(drag != nil)
                topBar
                if let drag {
                    ghost(drag)
                        .position(x: drag.location.x - origin.x - drag.grab.width + drag.size.width / 2, y: drag.location.y - origin.y - drag.grab.height + drag.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(TileFramesKey.self) { frames = $0 }
            .onPreferenceChange(BackButtonFrameKey.self) { backFrame = $0 }
            .onPreferenceChange(TopBarHeightKey.self) { topBarBottom = $0 }
        }
        .onAppear {
            if let notebookId, library.notebook(notebookId) == nil {
                navigator.go(.library)
            }
        }
    }

    private var title: String {
        notebookId.flatMap { library.notebook($0)?.title } ?? "Folders"
    }

    private var label: String {
        guard let notebookId else {
            let count = library.folders(in: nil).count
            return "\(count) folder\(count == 1 ? "" : "s")"
        }
        return summary(notebookId)
    }

    private func summary(_ notebookId: String) -> String {
        let notes = library.pages(in: notebookId).count
        let folders = library.folders(in: notebookId).count
        let noteText = "\(notes) note\(notes == 1 ? "" : "s")"
        return folders > 0 ? "\(noteText) · \(folders) folder\(folders == 1 ? "" : "s")" : noteText
    }

    private var topBar: some View {
        TopBar(
            title: title,
            label: label,
            onBack: notebookId == nil ? nil : goBack,
            onTitle: titleAction
        ) {
            SearchField(text: $query)
            SettingsButton()
        }
    }

    private var titleAction: (() -> Void)? {
        guard let notebookId else { return nil }
        return { navigator.show(.renameFolder(notebookId)) }
    }

    private func goBack() {
        guard let notebookId else { return }
        if let parent = library.parent(of: notebookId) {
            navigator.go(.notebook(parent))
        } else {
            navigator.go(.library)
        }
    }

    @ViewBuilder
    private var browse: some View {
        if notebookId != nil {
            heading("Folders")
        }
        LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 18) {
            AddTile(glyph: "folder", title: "Add folder", aspect: 1.25, isFolder: true) {
                navigator.show(.newFolder(parentId: notebookId))
            }
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                folderTile(folder, rank: index + 1, isDraggable: true)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, notebookId == nil ? 24 : 12)
        if let notebookId {
            heading("Notes")
                .padding(.top, 12)
            LazyVGrid(columns: noteColumns, alignment: .leading, spacing: 18) {
                AddTile(glyph: "note", title: "Add note", aspect: PaperGeometry.cellWidth / PaperGeometry.cellHeight, isFolder: false) {
                    navigator.show(.newNote(notebookId: notebookId))
                }
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, page in
                    noteTile(page, rank: index + 1, isDraggable: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var results: some View {
        let matchingFolders = library.liveNotebooks.filter { $0.title.lowercased().contains(trimmedQuery) }
        let matchingNotes = library.liveNotebooks.flatMap { library.pages(in: $0.id) }.filter { library.noteTitle($0).lowercased().contains(trimmedQuery) }
        if !matchingFolders.isEmpty {
            heading("Folders")
            LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 18) {
                ForEach(Array(matchingFolders.enumerated()), id: \.element.id) { index, folder in
                    folderTile(folder, rank: index, isDraggable: false)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }
        if !matchingNotes.isEmpty {
            heading("Notes")
                .padding(.top, 12)
            LazyVGrid(columns: noteColumns, alignment: .leading, spacing: 18) {
                ForEach(Array(matchingNotes.enumerated()), id: \.element.id) { index, page in
                    noteTile(page, rank: index, isDraggable: false)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }
        if matchingFolders.isEmpty && matchingNotes.isEmpty {
            HStack {
                Spacer()
                MicroLabel(text: "Nothing found")
                Spacer()
            }
            .padding(.vertical, 96)
        }
    }

    private func heading(_ text: String) -> some View {
        MicroLabel(text: text)
            .padding(.horizontal, 28)
            .padding(.top, 18)
    }

    private func folderTile(_ folder: Notebook, rank: Int, isDraggable: Bool) -> some View {
        let isResult = !isDraggable
        let caption = isResult && library.parent(of: folder.id) != nil ? library.path(of: library.parent(of: folder.id) ?? "") : summary(folder.id)
        return FolderTile(notebook: folder, caption: caption, firstPage: library.pages(in: folder.id).first, rank: rank)
            .modifier(TileBehaviour(
                key: "folder:\(folder.id)",
                isDraggable: isDraggable,
                isSource: drag?.id == folder.id,
                isTarget: drag?.target == .into(folder.id),
                callbacks: callbacks(kind: .folder, id: folder.id, isDraggable: isDraggable, onTap: { navigator.go(.notebook(folder.id)) }, onMenu: { showFolderMenu(folder.id, around: $0) })
            ))
    }

    private func noteTile(_ page: Page, rank: Int, isDraggable: Bool) -> some View {
        let caption = isDraggable ? (page.extent.cellCount > 1 ? "\(page.extent.columns)×\(page.extent.rows)" : "") : library.path(of: page.notebook)
        return NoteTile(page: page, title: library.noteTitle(page), caption: caption, rank: rank)
            .modifier(TileBehaviour(
                key: "note:\(page.id)",
                isDraggable: isDraggable,
                isSource: drag?.id == page.id,
                isTarget: false,
                callbacks: callbacks(kind: .note, id: page.id, isDraggable: isDraggable, onTap: { navigator.go(.page(notebookId: page.notebook, pageId: page.id)) }, onMenu: { showNoteMenu(page.id, around: $0) })
            ))
    }

    private func callbacks(kind: TileKind, id: String, isDraggable: Bool, onTap: @escaping () -> Void, onMenu: @escaping (CGRect) -> Void) -> TileCallbacks {
        TileCallbacks(
            onTap: onTap,
            onMenu: onMenu,
            onDragBegin: isDraggable ? { location in beginDrag(kind: kind, id: id, at: location) } : nil,
            onDragMove: isDraggable ? { location in moveDrag(to: location) } : nil,
            onDragEnd: isDraggable ? { location, isDrop in endDrag(at: location, isDrop: isDrop) } : nil
        )
    }

    @ViewBuilder
    private func ghost(_ drag: TileDrag) -> some View {
        Group {
            switch drag.kind {
            case .folder:
                if let folder = library.notebook(drag.id) {
                    FolderTile(notebook: folder, caption: summary(folder.id), firstPage: library.pages(in: folder.id).first, rank: 0)
                }
            case .note:
                if let page = library.page(drag.id) {
                    NoteTile(page: page, title: library.noteTitle(page), caption: "", rank: 0)
                }
            }
        }
        .frame(width: drag.size.width)
        .scaleEffect(1.04)
        .shadow(color: .black.opacity(0.6), radius: 18, y: 14)
        .opacity(isIntoTarget(drag.target) ? 0.85 : 1)
    }

    private func isIntoTarget(_ target: DropTarget?) -> Bool {
        if case .some(.into) = target {
            return true
        }
        return false
    }

    private func beginDrag(kind: TileKind, id: String, at location: CGPoint) {
        menu.dismiss()
        guard let frame = frames["\(kind.rawValue):\(id)"] else { return }
        arrangedFolders = folders.map(\.id)
        arrangedNotes = notes.map(\.id)
        drag = TileDrag(kind: kind, id: id, location: location, grab: CGSize(width: location.x - frame.minX, height: location.y - frame.minY), size: frame.size, target: nil)
    }

    private func moveDrag(to location: CGPoint) {
        guard var current = drag else { return }
        current.location = location
        let target = dropTarget(for: current, at: location)
        current.target = target
        drag = current
        switch target {
        case .before(let otherId), .after(let otherId):
            let isAfter: Bool
            if case .after = target {
                isAfter = true
            } else {
                isAfter = false
            }
            withAnimation(Motion.powerTwoOut(Tokens.shared.motion.durations.navSlide)) {
                if current.kind == .folder {
                    arrangedFolders = moved(arrangedFolders ?? [], current.id, next: otherId, isAfter: isAfter)
                } else {
                    arrangedNotes = moved(arrangedNotes ?? [], current.id, next: otherId, isAfter: isAfter)
                }
            }
        default:
            break
        }
    }

    private func moved(_ order: [String], _ id: String, next otherId: String, isAfter: Bool) -> [String] {
        var result = order.filter { $0 != id }
        guard let index = result.firstIndex(of: otherId) else { return order }
        result.insert(id, at: isAfter ? index + 1 : index)
        return result
    }

    private func dropTarget(for drag: TileDrag, at location: CGPoint) -> DropTarget? {
        if let notebookId, backFrame.contains(location) {
            let parentId = library.parent(of: notebookId)
            return drag.kind == .folder || parentId != nil ? .up(parentId) : nil
        }
        for (key, frame) in frames where frame.contains(location) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] != drag.id, let kind = TileKind(rawValue: parts[0]) else { continue }
            let share = (location.x - frame.minX) / max(1, frame.width)
            if kind == .folder && (drag.kind == .note || (share > Self.dropEdgeShare && share < 1 - Self.dropEdgeShare)) {
                if drag.kind == .folder && !library.canMoveNotebook(drag.id, into: parts[1]) {
                    return nil
                }
                return .into(parts[1])
            }
            guard kind == drag.kind else { return nil }
            return share < 0.5 ? .before(parts[1]) : .after(parts[1])
        }
        return drag.target.flatMap { target in
            if case .before = target { return target }
            if case .after = target { return target }
            return nil
        }
    }

    private func endDrag(at location: CGPoint, isDrop: Bool) {
        guard let current = drag else { return }
        let target = isDrop ? dropTarget(for: current, at: location) : nil
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            drag = nil
        }
        switch target {
        case .into(let folderId):
            moveItem(current, into: folderId)
        case .up(let parentId):
            if current.kind == .folder {
                library.moveNotebook(current.id, into: parentId)
            } else if let parentId {
                library.movePage(current.id, to: parentId)
            }
        default:
            if isDrop {
                if current.kind == .folder, let arrangedFolders {
                    library.arrangeFolders(arrangedFolders)
                } else if current.kind == .note, let arrangedNotes {
                    library.arrangePages(arrangedNotes)
                }
            }
        }
        arrangedFolders = nil
        arrangedNotes = nil
    }

    private func moveItem(_ drag: TileDrag, into folderId: String) {
        if drag.kind == .folder {
            library.moveNotebook(drag.id, into: folderId)
        } else {
            library.movePage(drag.id, to: folderId)
        }
    }

    private static func menuTitle(_ action: String) -> String {
        switch action {
        case "rename": return "Rename"
        case "appearance": return "Icon & colour"
        case "move": return "Move"
        case "delete_notebook", "delete_page": return "Delete"
        default: return action
        }
    }

    private func showFolderMenu(_ folderId: String, around frame: CGRect) {
        guard let folder = library.notebook(folderId) else { return }
        let slots = MenuSlot.fromTokens(Tokens.shared.menus.notebook, title: Self.menuTitle, perform: { action in
            switch action {
            case "rename": navigator.show(.renameFolder(folderId))
            case "appearance": navigator.show(.appearance(.folder(folderId)))
            case "move": navigator.show(.move(.folder(folderId)))
            case "delete_notebook": library.deleteNotebook(folderId)
            default: break
            }
        })
        menu.present(slots, columns: 2, around: frame, title: folder.title)
    }

    private func showNoteMenu(_ pageId: String, around frame: CGRect) {
        guard let page = library.page(pageId) else { return }
        let isReadOnly = library.isReadOnly(pageId)
        let slots = MenuSlot.fromTokens(Tokens.shared.menus.pageTile, title: Self.menuTitle, isEnabled: { action in action == "delete_page" || !isReadOnly }, perform: { action in
            switch action {
            case "rename": navigator.show(.renameNote(pageId))
            case "appearance": navigator.show(.appearance(.note(pageId)))
            case "move": navigator.show(.move(.note(pageId)))
            case "delete_page": library.deletePage(pageId)
            default: break
            }
        })
        menu.present(slots, columns: 2, around: frame, title: library.noteTitle(page))
    }
}

private struct TileBehaviour: ViewModifier {
    let key: String
    let isDraggable: Bool
    let isSource: Bool
    let isTarget: Bool
    let callbacks: TileCallbacks

    @State private var isPressed = false

    func body(content: Content) -> some View {
        var interaction = callbacks
        interaction.onPress = { pressed in isPressed = pressed }
        return content
            .scaleEffect(isTarget ? 1.04 : (isPressed ? 0.97 : 1))
            .overlay(Squircle.panel.stroke(Palette.accent, lineWidth: 2).opacity(isTarget ? 1 : 0))
            .opacity(isSource ? 0.25 : 1)
            .overlay(TileInteraction(callbacks: interaction))
            .background(GeometryReader { proxy in Color.clear.preference(key: TileFramesKey.self, value: isDraggable ? [key: proxy.frame(in: .global)] : [:]) })
            .animation(isPressed ? Motion.powerTwoOut(Motion.pressMilliseconds) : Motion.backOut(Motion.releaseMilliseconds), value: isPressed)
            .animation(Motion.backOut(Motion.stateMilliseconds), value: isTarget)
    }
}

private struct Appear: ViewModifier {
    let rank: Int
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 14)
            .scaleEffect(isShown ? 1 : 0.94)
            .onAppear {
                withAnimation(Motion.powerTwoOut(240, delay: min(rank, 16) * 12)) {
                    isShown = true
                }
            }
    }
}

struct AddTile: View {
    let glyph: String
    let title: String
    let aspect: Double
    let isFolder: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: isFolder ? 12 : 10) {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Palette.borderHover, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .overlay(GlyphView(name: glyph, color: Palette.create, size: 34))
                    .aspectRatio(aspect, contentMode: .fit)
                HStack(spacing: 8) {
                    GlyphView(name: "plus", color: Palette.create, size: 16)
                    Text(title)
                        .font(Typography.monoBold(13))
                        .tracking(1)
                        .foregroundColor(Palette.create)
                }
                .frame(height: isFolder ? 44 : 18, alignment: isFolder ? .topLeading : .leading)
            }
            .padding(isFolder ? 14 : 12)
            .background((isFolder ? Squircle.panel : Squircle.tile).fill(Palette.ground))
            .overlay((isFolder ? Squircle.panel : Squircle.tile).stroke(Palette.borderControl, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle(pressedScale: 0.97))
        .modifier(Appear(rank: 0))
    }
}

struct FolderTile: View {
    let notebook: Notebook
    let caption: String
    let firstPage: Page?
    let rank: Int

    var body: some View {
        let look = Looks.folder(notebook)
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Squircle.tile.fill(Palette.sunkenDeep)
                if let firstPage {
                    PageThumbnail(page: firstPage)
                        .padding(10)
                } else {
                    GlyphView(name: look.icon, color: Color(hex: look.color), size: 44)
                }
            }
            .aspectRatio(1.25, contentMode: .fit)
            HStack(alignment: .top, spacing: 10) {
                GlyphView(name: look.icon, color: Color(hex: look.color), size: 22)
                    .frame(width: 24, height: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text(notebook.title)
                        .font(Typography.heading(19))
                        .foregroundColor(Palette.textBright)
                        .lineLimit(1)
                    MicroLabel(text: caption)
                }
            }
        }
        .padding(14)
        .background(Squircle.panel.fill(Palette.panelSolid))
        .overlay(Squircle.panel.stroke(Palette.border, lineWidth: 1))
        .modifier(Appear(rank: rank))
    }
}

struct NoteTile: View {
    let page: Page
    let title: String
    let caption: String
    let rank: Int

    var body: some View {
        let look = Looks.note(page)
        VStack(alignment: .leading, spacing: 10) {
            PageThumbnail(page: page)
                .aspectRatio(CGFloat(PaperGeometry.width(of: page.extent) / PaperGeometry.height(of: page.extent)), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(Squircle(radius: 6))
            HStack(spacing: 8) {
                GlyphView(name: look.icon, color: Color(hex: look.color), size: 16)
                Text(title)
                    .font(Typography.mono(12))
                    .foregroundColor(Palette.textBright)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !caption.isEmpty {
                    MicroLabel(text: caption)
                }
            }
            .frame(minHeight: 18)
        }
        .padding(12)
        .background(Squircle.tile.fill(Palette.panelSolid))
        .overlay(Squircle.tile.stroke(Palette.border, lineWidth: 1))
        .modifier(Appear(rank: rank))
    }
}

struct PageThumbnail: View {
    let page: Page
    @EnvironmentObject private var preferences: Preferences
    @State private var image: UIImage?
    @State private var renderedKey: String?
    @State private var importRevision = 0

    private var key: String {
        "\(page.id)-\(page.updated.timeIntervalSince1970)-\(page.extent.columns)x\(page.extent.rows)-\(preferences.showsGuides)-\(preferences.showsDividers)-\(preferences.paperStyle.rawValue)-\(importRevision)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { render(size: proxy.size) }
            .onChange(of: key) { _, _ in render(size: proxy.size) }
            .onChange(of: proxy.size) { _, size in
                renderedKey = nil
                render(size: size)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ImportImages.didRender)) { _ in
            importRevision += 1
        }
    }

    private func render(size: CGSize) {
        guard renderedKey != key, size.width > 0, size.height > 0 else { return }
        renderedKey = key
        let options = RenderOptions(showsGuides: preferences.showsGuides, showsDividers: preferences.showsDividers, paperStyle: preferences.paperStyle, pixelScale: UIScreen.main.scale)
        image = PageRenderer.thumbnail(of: page, size: size, options: options)
    }
}
