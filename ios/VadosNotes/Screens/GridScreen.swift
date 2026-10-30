import NotesCore
import SwiftUI

extension Library {
    func folderSummary(_ notebookId: String) -> String {
        let noteCount = pages(in: notebookId).count
        let folderCount = folders(in: notebookId).count
        let noteText = "\(noteCount) note\(noteCount == 1 ? "" : "s")"
        return folderCount > 0 ? "\(noteText) · \(folderCount) folder\(folderCount == 1 ? "" : "s")" : noteText
    }
}

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
    let groupId: String?
    var location: CGPoint
    let grab: CGSize
    let size: CGSize
    var target: DropTarget?

    var isLoose: Bool {
        guard groupId != nil, case .slot = target else { return false }
        return true
    }

    var slotIndex: Int? {
        guard case .slot(let index) = target else { return nil }
        return index
    }
}

private enum DropTarget: Equatable {
    case into(String)
    case up(String?)
    case group(String)
    case slot(Int)
}

struct GridScreen: View {
    let notebookId: String?

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.chromeLayout) private var chrome
    @State private var frames: [String: CGRect] = [:]
    @State private var drag: TileDrag?
    @State private var arrangedFolders: [String]?
    @State private var arrangedNotes: [String]?
    @State private var openGroups: Set<String> = []
    @State private var isSwipeSpent = false

    private let folderColumns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18, alignment: .top)]
    private let noteColumns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 18, alignment: .top)]
    private static let dropEdgeShare: CGFloat = 0.22
    private static let noteColumnWidth: CGFloat = 170
    private static let folderColumnWidth: CGFloat = 230
    private static let tileSpacing: CGFloat = 18
    private static let slotReach: CGFloat = 48
    private static let groupSwipeDistance: CGFloat = 24

    private var folderLayout: MasonryLayout {
        MasonryLayout(minimumColumnWidth: Self.folderColumnWidth, spacing: Self.tileSpacing, unitHeight: Self.folderUnitHeight)
    }

    private var noteLayout: MasonryLayout {
        MasonryLayout(minimumColumnWidth: Self.noteColumnWidth, spacing: Self.tileSpacing, unitHeight: Self.noteUnitHeight)
    }

    private var trimmedQuery: String {
        navigator.query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var groups: [TileGroup] {
        preferences.groups(in: notebookId)
    }

    private func isGrouped(_ id: String) -> Bool {
        groups.contains { $0.members.contains(id) }
    }

    private func isShownInGrid(_ id: String) -> Bool {
        !isGrouped(id) || (drag?.id == id && drag?.isLoose == true)
    }

    private var folders: [Notebook] {
        let items = library.folders(in: notebookId).filter { isShownInGrid($0.id) }
        guard let arrangedFolders else { return items }
        return arrangedFolders.compactMap { id in items.first { $0.id == id } }
    }

    private var notes: [Page] {
        guard let notebookId else { return [] }
        let items = library.pages(in: notebookId).filter { isShownInGrid($0.id) }
        guard let arrangedNotes else { return items }
        return arrangedNotes.compactMap { id in items.first { $0.id == id } }
    }

    var body: some View {
        let _ = library.revision
        let _ = preferences.revision
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: max(0, chrome.bottom - origin.y))
                        Group {
                            if trimmedQuery.isEmpty {
                                browse
                            } else {
                                results
                            }
                        }
                        .id(notebookId ?? "root")
                        .transition(.folder)
                    }
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture(perform: closeGroups))
                    .simultaneousGesture(groupSwipe)
                }
                .scrollDisabled(drag != nil)
                if let drag {
                    ghost(drag)
                        .position(x: drag.location.x - origin.x - drag.grab.width + drag.size.width / 2, y: drag.location.y - origin.y - drag.grab.height + drag.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(TileFramesKey.self) { frames = $0 }
        }
        .onAppear(perform: leaveIfMissing)
        .onChange(of: notebookId) { _, _ in
            drag = nil
            arrangedFolders = nil
            arrangedNotes = nil
            leaveIfMissing()
        }
    }

    private func leaveIfMissing() {
        if let notebookId, library.notebook(notebookId) == nil {
            navigator.go(.library)
        }
    }

    private func hasGroups(isFolders: Bool) -> Bool {
        groups.contains { $0.isFolders == isFolders }
    }

    private func closeGroups() {
        guard !openGroups.isEmpty else { return }
        Haptics.tick()
        openGroups.removeAll()
    }

    private var groupSwipe: some Gesture {
        DragGesture(minimumDistance: Self.groupSwipeDistance, coordinateSpace: .global)
            .onChanged { _ in
                if drag != nil {
                    isSwipeSpent = true
                }
            }
            .onEnded { value in
                defer { isSwipeSpent = false }
                guard !isSwipeSpent, drag == nil, abs(value.translation.width) > abs(value.translation.height) else { return }
                let startsInGroup = openGroups.contains { frames["group:\($0)"]?.contains(value.startLocation) == true }
                if !startsInGroup {
                    closeGroups()
                }
            }
    }

    private func areaReport(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TileFramesKey.self, value: [key: proxy.frame(in: .global)])
        }
    }

    @ViewBuilder
    private var browse: some View {
        foldersSection
        if let notebookId {
            notesSection(notebookId)
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        if notebookId == nil || !folders.isEmpty || hasGroups(isFolders: true) {
            if notebookId != nil {
                heading("Folders")
            }
            groupRows(isFolders: true)
            folderLayout {
                if notebookId == nil {
                    AddTile(glyph: "folder", title: "Add folder", aspect: 1.25, isFolder: true) {
                        navigator.show(.newFolder(parentId: nil))
                    }
                }
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                    folderTile(folder, rank: index + 1, isDraggable: true)
                }
            }
            .animation(Motion.placement, value: folders.map(\.id))
            .background(areaReport("folders"))
            .padding(.horizontal, 28)
            .padding(.top, notebookId == nil ? 24 : 12)
        }
    }

    @ViewBuilder
    private func notesSection(_ notebookId: String) -> some View {
        heading("Notes")
            .padding(.top, 12)
        groupRows(isFolders: false)
        noteLayout {
            VStack(spacing: Self.tileSpacing) {
                CompactAddTile(glyph: "note", title: "Add note") {
                    navigator.show(.newNote(notebookId: notebookId))
                }
                CompactAddTile(glyph: "folder", title: "Add folder") {
                    navigator.show(.newFolder(parentId: notebookId))
                }
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, page in
                noteTile(page, rank: index + 1, isDraggable: true)
                    .layoutValue(key: MasonrySpan.self, value: page.extent.columns)
                    .layoutValue(key: MasonryRows.self, value: page.extent.rows)
            }
        }
        .animation(Motion.placement, value: notes.map(\.id))
        .background(areaReport("notes"))
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    static func noteUnitHeight(_ width: CGFloat) -> CGFloat {
        (width - 24) * CGFloat(PaperGeometry.cellHeight / PaperGeometry.cellWidth) + 24 + 10 + TileIcons.note
    }

    static func folderUnitHeight(_ width: CGFloat) -> CGFloat {
        (width - 28) / 1.25 + 28 + 12 + 44
    }

    @ViewBuilder
    private func groupRows(isFolders: Bool) -> some View {
        let shown = groups.filter { $0.isFolders == isFolders }.map { group -> TileGroup in
            var live = group
            live.members = group.members.filter { id in isFolders ? library.notebook(id) != nil && library.parent(of: id) == notebookId : library.page(id)?.notebook == notebookId }
            return live
        }.filter { !$0.members.isEmpty }
        ForEach(shown) { group in
            let isDropTarget = drag?.target == .group(group.id) && drag?.groupId != group.id
            StackGroupView(
                group: group,
                caption: "\(group.members.count) \(isFolders ? "folder" : "note")\(group.members.count == 1 ? "" : "s")",
                isOpen: openGroups.contains(group.id),
                isSwipeEnabled: drag == nil,
                cardHeight: { cell in isFolders ? Self.folderUnitHeight(cell) : Self.noteUnitHeight(cell) },
                onToggle: { isOpen in
                    if isOpen {
                        openGroups.insert(group.id)
                    } else {
                        openGroups.remove(group.id)
                    }
                },
                onMenu: { point in showGroupMenu(group, at: point) },
                card: { id in groupCard(id, isFolders: isFolders, groupId: group.id) }
            )
            .background(areaReport("group:\(group.id)"))
            .overlay(Squircle.panel.stroke(Palette.accent, lineWidth: 2).padding(-8).opacity(isDropTarget ? 1 : 0).allowsHitTesting(false))
            .animation(Motion.backOut(Motion.stateMilliseconds), value: isDropTarget)
            .padding(.horizontal, 28)
            .padding(.top, 18)
        }
    }

    private func groupCard(_ id: String, isFolders: Bool, groupId: String) -> AnyView {
        if isFolders, let folder = library.notebook(id) {
            return AnyView(folderTile(folder, rank: 0, isDraggable: true, groupId: groupId))
        }
        if let page = library.page(id) {
            return AnyView(noteTile(page, rank: 0, isDraggable: true, groupId: groupId))
        }
        return AnyView(EmptyView())
    }

    @ViewBuilder
    private var results: some View {
        let matchingFolders = library.liveNotebooks.filter { $0.title.lowercased().contains(trimmedQuery) }
        let matchingNotes = library.liveNotebooks.flatMap { library.pages(in: $0.id) }.filter { library.noteTitle($0).lowercased().contains(trimmedQuery) }
        if !matchingFolders.isEmpty {
            heading("Folders")
            LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 18) {
                ForEach(Array(matchingFolders.enumerated()), id: \.element.id) { index, folder in
                    folderTile(folder, rank: index, isDraggable: false, isResult: true)
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
                    noteTile(page, rank: index, isDraggable: false, isResult: true)
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

    private func frameKey(_ kind: TileKind, _ id: String, groupId: String?) -> String {
        groupId == nil ? "\(kind.rawValue):\(id)" : "member:\(id)"
    }

    private func folderTile(_ folder: Notebook, rank: Int, isDraggable: Bool, isResult: Bool = false, groupId: String? = nil) -> some View {
        let caption = isResult && library.parent(of: folder.id) != nil ? library.path(of: library.parent(of: folder.id) ?? "") : library.folderSummary(folder.id)
        return FolderTile(notebook: folder, caption: caption, rank: rank)
            .modifier(TileBehaviour(
                key: frameKey(.folder, folder.id, groupId: groupId),
                isDraggable: isDraggable,
                isSource: drag?.id == folder.id,
                isHidden: groupId != nil && drag?.id == folder.id && drag?.isLoose == true,
                isTarget: drag?.target == .into(folder.id),
                callbacks: callbacks(kind: .folder, id: folder.id, groupId: groupId, isDraggable: isDraggable, onTap: { _ in navigator.go(.notebook(folder.id)) }, onMenu: { showFolderMenu(folder.id, at: $0) })
            ))
    }

    private func noteTile(_ page: Page, rank: Int, isDraggable: Bool, isResult: Bool = false, groupId: String? = nil) -> some View {
        let caption = isResult ? library.path(of: page.notebook) : (page.extent.cellCount > 1 ? "\(page.extent.columns)×\(page.extent.rows)" : "")
        return NoteTile(page: page, title: library.noteTitle(page), caption: caption, rank: rank)
            .modifier(TileBehaviour(
                key: frameKey(.note, page.id, groupId: groupId),
                isDraggable: isDraggable,
                isSource: drag?.id == page.id,
                isHidden: groupId != nil && drag?.id == page.id && drag?.isLoose == true,
                isTarget: false,
                callbacks: callbacks(kind: .note, id: page.id, groupId: groupId, isDraggable: isDraggable, onTap: { frame in navigator.go(.page(notebookId: page.notebook, pageId: page.id), from: frame) }, onMenu: { showNoteMenu(page.id, at: $0) })
            ))
    }

    private func callbacks(kind: TileKind, id: String, groupId: String?, isDraggable: Bool, onTap: @escaping (CGRect) -> Void, onMenu: @escaping (CGPoint) -> Void) -> TileCallbacks {
        TileCallbacks(
            onTap: onTap,
            onMenu: onMenu,
            onDragBegin: isDraggable ? { location in beginDrag(kind: kind, id: id, groupId: groupId, at: location) } : nil,
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
                    FolderTile(notebook: folder, caption: library.folderSummary(folder.id), rank: 0, isEntering: false)
                }
            case .note:
                if let page = library.page(drag.id) {
                    NoteTile(page: page, title: library.noteTitle(page), caption: "", rank: 0, isEntering: false)
                }
            }
        }
        .frame(width: drag.size.width, height: drag.size.height)
        .scaleEffect(CGFloat(Motion.scales.held), anchor: UnitPoint(x: drag.grab.width / max(1, drag.size.width), y: drag.grab.height / max(1, drag.size.height)))
        .shadow(color: .black.opacity(0.6), radius: 18, y: 14)
        .opacity(isIntoTarget(drag) ? 0.85 : 1)
    }

    private func isIntoTarget(_ drag: TileDrag) -> Bool {
        switch drag.target {
        case .into: return true
        case .group(let groupId): return groupId != drag.groupId
        default: return false
        }
    }

    private func beginDrag(kind: TileKind, id: String, groupId: String?, at location: CGPoint) {
        menu.dismiss()
        guard let frame = frames[frameKey(kind, id, groupId: groupId)] else { return }
        arrangedFolders = folders.map(\.id)
        arrangedNotes = notes.map(\.id)
        drag = TileDrag(kind: kind, id: id, groupId: groupId, location: location, grab: CGSize(width: location.x - frame.minX, height: location.y - frame.minY), size: frame.size, target: nil)
    }

    private func moveDrag(to location: CGPoint) {
        guard var current = drag else { return }
        current.location = location
        if let target = dropTarget(for: current, at: location) {
            current.target = target
        } else if let index = slotIndex(for: current, at: location) {
            current.target = .slot(index)
        } else if current.slotIndex == nil {
            current.target = nil
        }
        drag = current
        guard let index = current.slotIndex else { return }
        let others = shownOrder(of: current.kind).filter { $0 != current.id }
        var order = others
        order.insert(current.id, at: min(index, others.count))
        guard order != shownOrder(of: current.kind) else { return }
        withAnimation(Motion.placement) {
            if current.kind == .folder {
                arrangedFolders = order
            } else {
                arrangedNotes = order
            }
        }
    }

    private func shownOrder(of kind: TileKind) -> [String] {
        (kind == .folder ? arrangedFolders : arrangedNotes) ?? []
    }

    private func dropTarget(for drag: TileDrag, at location: CGPoint) -> DropTarget? {
        if let notebookId, chrome.back.contains(location) {
            let parentId = library.parent(of: notebookId)
            return drag.kind == .folder || parentId != nil ? .up(parentId) : nil
        }
        if let folderId = folder(under: location, for: drag) {
            return .into(folderId)
        }
        if let group = groups.first(where: { $0.isFolders == (drag.kind == .folder) && frames["group:\($0.id)"]?.contains(location) == true }) {
            return .group(group.id)
        }
        return nil
    }

    private func folder(under location: CGPoint, for drag: TileDrag) -> String? {
        for (key, frame) in frames where frame.contains(location) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] != drag.id, library.notebook(parts[1]) != nil else { continue }
            switch (parts[0], drag.kind) {
            case ("folder", .note), ("member", .note):
                return parts[1]
            case ("folder", .folder):
                let share = (location.x - frame.minX) / max(1, frame.width)
                if share > Self.dropEdgeShare && share < 1 - Self.dropEdgeShare && library.canMoveNotebook(drag.id, into: parts[1]) {
                    return parts[1]
                }
            default:
                continue
            }
        }
        return nil
    }

    private func slotIndex(for drag: TileDrag, at location: CGPoint) -> Int? {
        let isFolder = drag.kind == .folder
        guard let area = frames[isFolder ? "folders" : "notes"] else { return nil }
        let order = shownOrder(of: drag.kind)
        let others = order.filter { $0 != drag.id }
        let leading = isFolder ? (notebookId == nil ? 1 : 0) : 1
        let extent: (String) -> Extent = { id in isFolder ? .single : library.page(id)?.extent ?? .single }
        let layout = isFolder ? folderLayout : noteLayout
        let candidates = (0...others.count).map { index -> CGRect in
            var cells = others.map(extent)
            cells.insert(extent(drag.id), at: index)
            let placed = layout.frames(width: area.width, extents: Array(repeating: Extent.single, count: leading) + cells)
            return placed[leading + index].offsetBy(dx: area.minX, dy: area.minY)
        }
        let isNear = area.insetBy(dx: -Self.slotReach, dy: -Self.slotReach).contains(location) || candidates.contains { $0.contains(location) }
        guard isNear else { return nil }
        let current = isShownInGrid(drag.id) ? order.firstIndex(of: drag.id) : nil
        if let current, candidates.indices.contains(current), candidates[current].contains(location) {
            return current
        }
        let containing = candidates.indices.filter { candidates[$0].contains(location) }
        let pool = containing.isEmpty ? Array(candidates.indices) : containing
        return pool.min { hypot(candidates[$0].midX - location.x, candidates[$0].midY - location.y) < hypot(candidates[$1].midX - location.x, candidates[$1].midY - location.y) }
    }

    private func endDrag(at location: CGPoint, isDrop: Bool) {
        if isDrop {
            moveDrag(to: location)
        }
        guard let current = drag else { return }
        withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
            drag = nil
        }
        if isDrop {
            commit(current)
        }
        arrangedFolders = nil
        arrangedNotes = nil
    }

    private func commit(_ current: TileDrag) {
        switch current.target {
        case .into(let folderId):
            leaveGroup(current)
            moveItem(current, into: folderId)
        case .up(let parentId):
            leaveGroup(current)
            if current.kind == .folder {
                library.moveNotebook(current.id, into: parentId)
            } else if let parentId {
                library.movePage(current.id, to: parentId)
            }
        case .group(let groupId):
            if groupId != current.groupId {
                preferences.addToGroup(current.id, groupId: groupId, in: notebookId)
            }
        case .slot, nil:
            if current.groupId != nil {
                guard current.isLoose else { return }
                leaveGroup(current)
            }
            if current.kind == .folder, let arrangedFolders {
                library.arrangeFolders(arrangedFolders)
            } else if current.kind == .note, let arrangedNotes {
                library.arrangePages(arrangedNotes)
            }
        }
    }

    private func leaveGroup(_ current: TileDrag) {
        if current.groupId != nil {
            preferences.removeFromGroup(current.id, in: notebookId)
        }
    }

    private func moveItem(_ drag: TileDrag, into folderId: String) {
        if drag.kind == .folder {
            library.moveNotebook(drag.id, into: folderId)
        } else {
            library.movePage(drag.id, to: folderId)
        }
    }

    private func menuTitle(_ action: String, memberId: String) -> String {
        switch action {
        case "rename": return "Rename"
        case "appearance": return "Icon & colour"
        case "move": return "Move"
        case "delete_notebook", "delete_page": return "Delete"
        case "group": return isGrouped(memberId) ? "Remove from group" : "Add to group"
        default: return action
        }
    }

    private func toggleGroup(_ target: TileTarget, memberId: String) {
        if isGrouped(memberId) {
            preferences.removeFromGroup(memberId, in: notebookId)
        } else {
            navigator.show(.pickGroup(target, parentId: notebookId))
        }
    }

    private func showFolderMenu(_ folderId: String, at point: CGPoint) {
        guard let folder = library.notebook(folderId) else { return }
        let slots = MenuSlot.fromTokens(Tokens.shared.menus.notebook + Tokens.shared.menus.grouping, title: { menuTitle($0, memberId: folderId) }, perform: { action in
            switch action {
            case "rename": navigator.show(.renameFolder(folderId))
            case "appearance": navigator.show(.appearance(.folder(folderId)))
            case "move": navigator.show(.move(.folder(folderId)))
            case "delete_notebook": library.deleteNotebook(folderId)
            case "group": toggleGroup(.folder(folderId), memberId: folderId)
            default: break
            }
        })
        menu.present(slots, at: point, title: folder.title)
    }

    private func showNoteMenu(_ pageId: String, at point: CGPoint) {
        guard let page = library.page(pageId) else { return }
        let isReadOnly = library.isReadOnly(pageId)
        let slots = MenuSlot.fromTokens(Tokens.shared.menus.pageTile + Tokens.shared.menus.grouping, title: { menuTitle($0, memberId: pageId) }, isEnabled: { action in action == "delete_page" || action == "group" || !isReadOnly }, perform: { action in
            switch action {
            case "rename": navigator.show(.renameNote(pageId))
            case "appearance": navigator.show(.appearance(.note(pageId)))
            case "move": navigator.show(.move(.note(pageId)))
            case "delete_page": library.deletePage(pageId)
            case "group": toggleGroup(.note(pageId), memberId: pageId)
            default: break
            }
        })
        menu.present(slots, at: point, title: library.noteTitle(page))
    }

    private func showGroupMenu(_ group: TileGroup, at point: CGPoint) {
        let slots = MenuSlot.fromTokens(Tokens.shared.menus.group, title: { action in
            switch action {
            case "rename": return "Rename"
            case "ungroup": return "Ungroup"
            default: return action
            }
        }, perform: { action in
            switch action {
            case "rename": navigator.show(.renameGroup(group.id, parentId: notebookId))
            case "ungroup":
                openGroups.remove(group.id)
                preferences.ungroup(group.id, in: notebookId)
            default: break
            }
        })
        menu.present(slots, at: point, title: group.title)
    }
}

private struct TileBehaviour: ViewModifier {
    let key: String
    let isDraggable: Bool
    let isSource: Bool
    let isHidden: Bool
    let isTarget: Bool
    let callbacks: TileCallbacks

    @State private var isPressed = false

    func body(content: Content) -> some View {
        var interaction = callbacks
        interaction.onPress = { pressed in isPressed = pressed }
        return content
            .modifier(HoldPop(isPressed: isPressed))
            .scaleEffect(isTarget ? 1.04 : 1)
            .overlay(Squircle.panel.stroke(Palette.accent, lineWidth: 2).opacity(isTarget ? 1 : 0))
            .opacity(isHidden ? 0 : isSource ? 0.25 : 1)
            .overlay(TileInteraction(callbacks: interaction))
            .background(GeometryReader { proxy in Color.clear.preference(key: TileFramesKey.self, value: isDraggable ? [key: proxy.frame(in: .global)] : [:]) })
            .animation(Motion.backOut(Motion.stateMilliseconds), value: isTarget)
    }
}

private struct Appear: ViewModifier {
    let rank: Int
    @State private var isShown: Bool

    init(rank: Int, isEntering: Bool = true) {
        self.rank = rank
        _isShown = State(initialValue: !isEntering)
    }

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 14)
            .scaleEffect(isShown ? 1 : 0.94)
            .onAppear {
                guard !isShown else { return }
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
                    .overlay(GlyphView(name: glyph, color: Palette.create, size: TileIcons.folder))
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
        .buttonStyle(PressableStyle())
        .modifier(Appear(rank: 0))
    }
}

enum TileIcons {
    static let folder: CGFloat = 64
    static let add: CGFloat = 40
    static let note: CGFloat = 22
}

struct CompactAddTile: View {
    let glyph: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                GlyphView(name: glyph, color: Palette.create, size: TileIcons.add)
                HStack(spacing: 8) {
                    GlyphView(name: "plus", color: Palette.create, size: 16)
                    Text(title)
                        .font(Typography.monoBold(13))
                        .tracking(1)
                        .foregroundColor(Palette.create)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Squircle.tile.fill(Palette.ground))
            .overlay(Squircle.tile.stroke(Palette.borderControl, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .contentShape(Squircle.tile)
        }
        .buttonStyle(PressableStyle())
        .modifier(Appear(rank: 0))
    }
}

struct FolderTile: View {
    let notebook: Notebook
    let caption: String
    let rank: Int
    var isEntering = true

    var body: some View {
        let look = Looks.folder(notebook)
        let color = Color(hex: look.color)
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Palette.sunkenDeep)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.35), lineWidth: 1))
                .overlay(GlyphView(name: look.icon, color: color, size: TileIcons.folder))
                .aspectRatio(1.25, contentMode: .fit)
            VStack(alignment: .leading, spacing: 6) {
                Text(notebook.title)
                    .font(Typography.heading(19))
                    .foregroundColor(Palette.textBright)
                    .lineLimit(1)
                MicroLabel(text: caption)
            }
            .frame(height: 44, alignment: .topLeading)
        }
        .padding(14)
        .background(Squircle.panel.fill(Palette.panelSolid))
        .overlay(Squircle.panel.stroke(color, lineWidth: 1.5))
        .modifier(Appear(rank: rank, isEntering: isEntering))
    }
}

struct NoteTile: View {
    let page: Page
    let title: String
    let caption: String
    let rank: Int
    var isEntering = true

    var body: some View {
        let look = Looks.note(page)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GlyphView(name: look.icon, color: Color(hex: look.color), size: TileIcons.note)
                Text(title)
                    .font(Typography.mono(12))
                    .foregroundColor(Palette.textBright)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !caption.isEmpty {
                    MicroLabel(text: caption)
                }
            }
            .frame(minHeight: TileIcons.note)
            PageThumbnail(page: page)
                .aspectRatio(CGFloat(PaperGeometry.width(of: page.extent) / PaperGeometry.height(of: page.extent)), contentMode: .fit)
                .clipShape(Squircle(radius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(Squircle.tile.fill(Palette.panelSolid))
        .overlay(Squircle.tile.stroke(Palette.border, lineWidth: 1))
        .modifier(Appear(rank: rank, isEntering: isEntering))
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

struct MasonrySpan: LayoutValueKey {
    static let defaultValue = 1
}

struct MasonryRows: LayoutValueKey {
    static let defaultValue = 1
}

struct MasonryLayout: Layout {
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat
    let unitHeight: (CGFloat) -> CGFloat

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        frames(width: width, extents: subviews.map { Extent(columns: $0[MasonrySpan.self], rows: $0[MasonryRows.self]) })
    }

    func frames(width: CGFloat, extents: [Extent]) -> [CGRect] {
        let grid = columns(for: width)
        var heights = Array(repeating: CGFloat(0), count: grid.count)
        return extents.map { extent in
            let span = min(grid.count, max(1, extent.columns))
            let rows = max(1, extent.rows)
            let tileWidth = grid.width * CGFloat(span) + spacing * CGFloat(span - 1)
            let size = CGSize(width: tileWidth, height: unitHeight(grid.width) * CGFloat(rows) + spacing * CGFloat(rows - 1))
            var bestColumn = 0
            var bestTop = CGFloat.infinity
            for column in 0...(grid.count - span) {
                let top = heights[column..<(column + span)].max() ?? 0
                if top < bestTop - 0.5 {
                    bestTop = top
                    bestColumn = column
                }
            }
            for column in bestColumn..<(bestColumn + span) {
                heights[column] = bestTop + size.height + spacing
            }
            return CGRect(x: CGFloat(bestColumn) * (grid.width + spacing), y: bestTop, width: tileWidth, height: size.height)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth * 3
        let height = frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
