import NotesCore
import SwiftUI
import UIKit

struct ExplorerEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case root
        case group
        case folder
        case note
    }

    let kind: Kind
    let targetId: String?
    let parentId: String?
    let groupTitle: String?
    let depth: Int
    let guide: String

    var id: String {
        switch kind {
        case .root: return "root"
        case .group: return "group-\(targetId ?? "")"
        case .folder: return "folder-\(targetId ?? "")"
        case .note: return "note-\(targetId ?? "")"
        }
    }
}

struct ExplorerDrag: Equatable {
    var entry: ExplorerEntry
    var location: CGPoint
    var targetKey: String?
}

private struct ExplorerRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

@MainActor
final class ExplorerModel: ObservableObject {
    @Published var expanded: Set<String> = []
    @Published var moving: ExplorerEntry?
    @Published var renamingKey: String?
    @Published var renameText = ""
    @Published var drag: ExplorerDrag?
    @Published var flashedKey: String?
    var rowFrames: [String: CGRect] = [:]
    var hoverWork: DispatchWorkItem?
}

struct ExplorerOverlay: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var menu: MenuController
    @Environment(\.screenInsets) private var insets
    @StateObject private var model = ExplorerModel()
    @FocusState private var isRenameFocused: Bool
    let screenSize: CGSize

    static let panelWidth: CGFloat = 380
    static let panelMargin: CGFloat = 12
    static let rowHeight: CGFloat = 40
    static let hoverExpandSeconds: Double = 0.6

    private var panelWidth: CGFloat {
        min(Self.panelWidth, screenSize.width - Self.panelMargin * 2)
    }

    private var isOpen: Bool { navigator.isExplorerOpen }

    private var currentFolderId: String? {
        switch navigator.route {
        case .library: return nil
        case .notebook(let notebookId): return notebookId
        case .page(let notebookId, _): return notebookId
        }
    }

    private var currentPageId: String? {
        if case .page(_, let pageId) = navigator.route {
            return pageId
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(isOpen ? 0.42 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { navigator.closeExplorer() }
                .allowsHitTesting(isOpen)
                .animation(isOpen ? Motion.powerTwoOut(Motion.explorerEnterMilliseconds) : Motion.powerTwoIn(Motion.explorerLeaveMilliseconds), value: isOpen)
            panel
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .padding(.top, Self.panelMargin + insets.top)
                .padding(.bottom, Self.panelMargin + insets.bottom)
                .padding(.trailing, Self.panelMargin + insets.trailing)
                .offset(x: isOpen ? 0 : panelWidth + Self.panelMargin * 2 + insets.trailing)
                .animation(isOpen ? Motion.backOut(Motion.explorerEnterMilliseconds) : Motion.powerTwoIn(Motion.explorerLeaveMilliseconds), value: isOpen)
                .allowsHitTesting(isOpen)
            if let drag = model.drag {
                ghost(drag)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onChange(of: isOpen) { _, open in
            if open {
                revealCurrent()
            } else {
                finishRename(committing: true)
                model.moving = nil
                model.drag = nil
            }
        }
        .onChange(of: navigator.route) { _, _ in
            if isOpen {
                revealCurrent()
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            crumbs
            Rectangle().fill(Palette.border).frame(height: 1)
            if let moving = model.moving {
                banner(moving)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries().enumerated()), id: \.element.id) { index, entry in
                            row(entry)
                                .id(entry.id)
                                .modifier(ExplorerRowArrival(isOpen: isOpen, order: index))
                        }
                    }
                    .scrollsToTopDisabled()
                    .padding(8)
                }
                .onPreferenceChange(ExplorerRowFramesKey.self) { model.rowFrames = $0 }
                .onChange(of: isOpen) { _, open in
                    guard open else { return }
                    DispatchQueue.main.async {
                        reader.scrollTo(currentKey, anchor: .center)
                    }
                }
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            footer
        }
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Palette.panelSolid))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, x: -12)
    }

    private var currentKey: String {
        if let currentPageId {
            return "note-\(currentPageId)"
        }
        return currentFolderId.map { "folder-\($0)" } ?? "root"
    }

    private var header: some View {
        HStack(spacing: 12) {
            MicroLabel(text: "Explorer")
            Text("DEPTH \(currentFolderId.map { library.depth(of: $0).count } ?? 0)")
                .font(Typography.mono(10))
                .tracking(2)
                .foregroundColor(Palette.ground)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.accent))
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            RoundIconButton(glyph: "close") { navigator.closeExplorer() }
                .accessibilityLabel("Close explorer")
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var crumbs: some View {
        let segments = currentFolderId.map { library.depth(of: $0) } ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                crumb("Library", group: nil, isCurrent: segments.isEmpty) { navigator.go(.library) }
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Text(index == 0 ? "›" : "/")
                        .font(Typography.mono(12))
                        .foregroundColor(Palette.textFaint)
                    crumb(segment.title, group: segment.group, isCurrent: index == segments.count - 1) {
                        model.expanded.insert(segment.id)
                        navigator.go(.notebook(segment.id))
                    }
                }
            }
            .scrollsToTopDisabled()
            .padding(.horizontal, 22)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func crumb(_ title: String, group: String?, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let group {
                    Text("\(group.uppercased()) -")
                        .foregroundColor(Palette.textFaint)
                }
                Text(title)
                    .foregroundColor(isCurrent ? Palette.accent : Palette.textMuted)
            }
            .font(Typography.mono(12))
            .lineLimit(1)
        }
        .buttonStyle(PressableStyle())
    }

    private func banner(_ moving: ExplorerEntry) -> some View {
        HStack(spacing: 10) {
            GlyphView(name: "move", color: Palette.navigation, size: 16)
            Text("MOVE \(title(of: moving).uppercased()) TO …")
                .font(Typography.mono(10))
                .tracking(1.5)
                .foregroundColor(Palette.navigation)
                .lineLimit(1)
            Spacer(minLength: 0)
            pill(glyph: "close", title: "Cancel", tint: Palette.textBody, height: 30) { model.moving = nil }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Palette.navigation.opacity(0.14)))
        .overlay(Capsule().stroke(Palette.navigation.opacity(0.55), lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .transition(.popTogether)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            pill(glyph: "folder_add", title: "Folder", tint: Palette.create) { createFolder(in: currentFolderId) }
            pill(glyph: "note_add", title: "Note", tint: Palette.create) {
                if let currentFolderId {
                    createNote(in: currentFolderId)
                }
            }
            .disabled(currentFolderId == nil)
            .opacity(currentFolderId == nil ? 0.35 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private func pill(glyph: String, title: String, tint: Color, height: CGFloat = 40, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GlyphView(name: glyph, color: tint, size: 16)
                Text(title.uppercased())
                    .font(Typography.mono(10))
                    .tracking(1.5)
                    .foregroundColor(Palette.textBody)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: height)
            .background(Capsule().fill(Palette.sunken))
            .overlay(Capsule().stroke(Palette.borderControl, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    private func entries() -> [ExplorerEntry] {
        var rows = [ExplorerEntry(kind: .root, targetId: nil, parentId: nil, groupTitle: nil, depth: 0, guide: "")]
        walk(parentId: nil, depth: 1, trail: [false], into: &rows)
        return rows
    }

    private enum Child {
        case group(TileGroup, isFolders: Bool)
        case folder(String)
        case note(String)
    }

    private func walk(parentId: String?, depth: Int, trail: [Bool], into rows: inout [ExplorerEntry]) {
        var children: [Child] = []
        var emitted: Set<String> = []
        let groups = library.groups(in: parentId)
        for folder in library.folders(in: parentId) {
            if let group = groups.first(where: { $0.isFolders && $0.members.contains(folder.id) }) {
                if !emitted.contains(group.id) {
                    emitted.insert(group.id)
                    children.append(.group(group, isFolders: true))
                }
                continue
            }
            children.append(.folder(folder.id))
        }
        if let parentId {
            for page in library.pages(in: parentId) {
                if let group = groups.first(where: { !$0.isFolders && $0.members.contains(page.id) }) {
                    if !emitted.contains(group.id) {
                        emitted.insert(group.id)
                        children.append(.group(group, isFolders: false))
                    }
                    continue
                }
                children.append(.note(page.id))
            }
        }
        for (index, child) in children.enumerated() {
            emit(child, parentId: parentId, depth: depth, trail: trail, isLast: index == children.count - 1, into: &rows)
        }
    }

    private func emit(_ child: Child, parentId: String?, depth: Int, trail: [Bool], isLast: Bool, into rows: inout [ExplorerEntry]) {
        let guide = Self.guideText(trail, isLast: isLast)
        switch child {
        case .group(let group, let isFolders):
            rows.append(ExplorerEntry(kind: .group, targetId: group.id, parentId: parentId, groupTitle: group.title, depth: depth, guide: guide))
            for (index, member) in group.members.enumerated() {
                let memberChild: Child = isFolders ? .folder(member) : .note(member)
                emit(memberChild, parentId: parentId, depth: depth + 1, trail: trail + [!isLast], isLast: index == group.members.count - 1, into: &rows)
            }
        case .folder(let folderId):
            rows.append(ExplorerEntry(kind: .folder, targetId: folderId, parentId: parentId, groupTitle: nil, depth: depth, guide: guide))
            if model.expanded.contains(folderId) {
                walk(parentId: folderId, depth: depth + 1, trail: trail + [!isLast], into: &rows)
            }
        case .note(let pageId):
            rows.append(ExplorerEntry(kind: .note, targetId: pageId, parentId: parentId, groupTitle: nil, depth: depth, guide: guide))
        }
    }

    private static func guideText(_ trail: [Bool], isLast: Bool) -> String {
        guard !trail.isEmpty else { return "" }
        return trail.dropFirst().map { $0 ? "│ " : "  " }.joined() + (isLast ? "└─" : "├─")
    }

    private func title(of entry: ExplorerEntry) -> String {
        switch entry.kind {
        case .root:
            return "Library"
        case .group:
            return entry.groupTitle ?? ""
        case .folder:
            return entry.targetId.flatMap { library.notebook($0)?.title } ?? "Folder"
        case .note:
            return entry.targetId.flatMap { library.page($0) }.map { library.noteTitle($0) } ?? "Note"
        }
    }

    @ViewBuilder
    private func row(_ entry: ExplorerEntry) -> some View {
        let isCurrent = entry.id == currentKey
        let isMovingSelf = model.moving?.id == entry.id
        let canDropMoving = model.moving.map { canDrop($0, on: entry) } ?? false
        let isDimmed = model.moving != nil && !isMovingSelf && !canDropMoving
        let isDropHover = model.drag?.targetKey == entry.id
        let isLifted = model.drag?.entry.id == entry.id
        HStack(spacing: 6) {
            if !entry.guide.isEmpty {
                Text(entry.guide)
                    .font(Typography.mono(13))
                    .tracking(-1)
                    .foregroundColor(Palette.textFaint)
                    .fixedSize()
            }
            chevron(entry)
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    icon(entry)
                    if model.renamingKey == entry.id {
                        TextField("", text: $model.renameText)
                            .font(Typography.mono(14))
                            .foregroundColor(Palette.textPrimary)
                            .tint(Palette.accent)
                            .focused($isRenameFocused)
                            .submitLabel(.done)
                            .onSubmit { finishRename(committing: true) }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sunkenDeep))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.accent, lineWidth: 1))
                            .onAppear { isRenameFocused = true }
                            .onChange(of: isRenameFocused) { _, focused in
                                if !focused {
                                    finishRename(committing: true)
                                }
                            }
                    } else {
                        rowTitle(entry, isOnPath: isOnPath(entry))
                        Spacer(minLength: 4)
                        Text(meta(entry))
                            .font(Typography.mono(9))
                            .tracking(1)
                            .foregroundColor(Palette.textFaint)
                            .lineLimit(1)
                    }
                }
                if model.renamingKey != entry.id && entry.kind != .group {
                    TileInteraction(callbacks: callbacks(entry))
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropHover ? Palette.navigation.opacity(0.22) : model.flashedKey == entry.id ? Palette.accent.opacity(0.22) : isCurrent ? Palette.accent.opacity(0.13) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Palette.accent).frame(width: 3, height: 20)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isDropHover || isMovingSelf ? Palette.navigation : Color.clear, style: StrokeStyle(lineWidth: 1, dash: isMovingSelf ? [4, 3] : []))
        )
        .opacity(isLifted ? 0.3 : isDimmed ? 0.32 : 1)
        .animation(Motion.powerTwoOut(Motion.pressMilliseconds), value: isDropHover)
        .animation(Motion.powerTwoOut(Motion.sweepRetractMilliseconds), value: model.flashedKey)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ExplorerRowFramesKey.self, value: [entry.id: proxy.frame(in: .global)])
        })
    }

    @ViewBuilder
    private func chevron(_ entry: ExplorerEntry) -> some View {
        let hasChildren = entry.kind == .folder && entry.targetId.map { !library.folders(in: $0).isEmpty || !library.pages(in: $0).isEmpty } == true
        let isExpanded = entry.targetId.map { model.expanded.contains($0) } ?? false
        Button {
            guard let folderId = entry.targetId else { return }
            withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                if isExpanded {
                    model.expanded.remove(folderId)
                } else {
                    model.expanded.insert(folderId)
                }
            }
        } label: {
            GlyphView(name: "chevron", color: Palette.textMuted, size: 14)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(Motion.backOut(Motion.stateMilliseconds), value: isExpanded)
                .frame(width: 22, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hasChildren ? 1 : 0)
        .disabled(!hasChildren)
        .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder
    private func icon(_ entry: ExplorerEntry) -> some View {
        switch entry.kind {
        case .root:
            GlyphView(name: "home", color: Palette.textBody, size: 18)
        case .group:
            GlyphView(name: "stack", color: Palette.textMuted, size: 16)
        case .folder:
            let look = Looks.folder(entry.targetId.flatMap { library.notebook($0) })
            GlyphView(name: look.icon, color: Color(hex: look.color), size: 18)
        case .note:
            let look = Looks.note(entry.targetId.flatMap { library.page($0) })
            GlyphView(name: look.icon, color: Color(hex: look.color), size: 16)
        }
    }

    @ViewBuilder
    private func rowTitle(_ entry: ExplorerEntry, isOnPath: Bool) -> some View {
        if entry.kind == .root || entry.kind == .group {
            MicroLabel(text: title(of: entry))
        } else {
            Text(title(of: entry))
                .font(Typography.mono(14))
                .foregroundColor(isOnPath ? Palette.textBright : Palette.textBody)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func meta(_ entry: ExplorerEntry) -> String {
        switch entry.kind {
        case .root:
            return "\(library.folders(in: nil).count)"
        case .folder:
            return entry.targetId.map { library.folderSummary($0).uppercased() } ?? ""
        default:
            return ""
        }
    }

    private func isOnPath(_ entry: ExplorerEntry) -> Bool {
        guard entry.kind == .folder, let folderId = entry.targetId, let currentFolderId, currentFolderId != folderId else { return false }
        return library.isInside(currentFolderId, folderId)
    }

    private func callbacks(_ entry: ExplorerEntry) -> TileCallbacks {
        let isMovable = entry.kind == .folder || entry.kind == .note
        return TileCallbacks(
            onTap: { _ in activate(entry) },
            onMenu: { point in showMenu(entry, at: point) },
            onDragBegin: isMovable ? { point in beginDrag(entry, at: point) } : nil,
            onDragMove: isMovable ? { point in moveDrag(to: point) } : nil,
            onDragEnd: isMovable ? { point, isDropped in endDrag(at: point, isDropped: isDropped) } : nil
        )
    }

    private func ghost(_ drag: ExplorerDrag) -> some View {
        HStack(spacing: 8) {
            icon(drag.entry)
            Text(title(of: drag.entry))
                .font(Typography.mono(14))
                .foregroundColor(Palette.textBright)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .background(Capsule().fill(Palette.raised))
        .overlay(Capsule().stroke(Palette.accent, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 20, y: 16)
        .scaleEffect(CGFloat(Motion.scales.held))
        .position(drag.location)
        .allowsHitTesting(false)
        .transition(.popTogether)
    }

    private func revealCurrent() {
        var current = currentFolderId
        var visited: Set<String> = []
        while let folderId = current, !visited.contains(folderId) {
            visited.insert(folderId)
            model.expanded.insert(folderId)
            current = library.parent(of: folderId)
        }
    }

    private func activate(_ entry: ExplorerEntry) {
        if let moving = model.moving {
            if canDrop(moving, on: entry) {
                perform(move: moving, to: entry)
            }
            return
        }
        switch entry.kind {
        case .root:
            navigator.go(.library)
        case .folder:
            guard let folderId = entry.targetId else { return }
            model.expanded.insert(folderId)
            navigator.go(.notebook(folderId))
        case .note:
            guard let pageId = entry.targetId, let page = library.page(pageId) else { return }
            navigator.closeExplorer()
            navigator.go(.page(notebookId: page.notebook, pageId: page.id))
        case .group:
            break
        }
    }

    private func canDrop(_ entry: ExplorerEntry, on target: ExplorerEntry) -> Bool {
        guard let movedId = entry.targetId else { return false }
        switch entry.kind {
        case .folder:
            if target.kind == .root {
                return library.parent(of: movedId) != nil
            }
            guard target.kind == .folder, let targetId = target.targetId else { return false }
            return library.canMoveNotebook(movedId, into: targetId) && library.parent(of: movedId) != targetId
        case .note:
            guard target.kind == .folder, let targetId = target.targetId else { return false }
            return library.page(movedId)?.notebook != targetId && !library.isReadOnly(movedId)
        default:
            return false
        }
    }

    private func perform(move entry: ExplorerEntry, to target: ExplorerEntry) {
        model.moving = nil
        guard let movedId = entry.targetId else { return }
        switch entry.kind {
        case .folder:
            library.moveNotebook(movedId, into: target.kind == .root ? nil : target.targetId)
            if let targetId = target.targetId {
                model.expanded.insert(targetId)
            }
            flash(entry.id)
        case .note:
            guard let targetId = target.targetId else { return }
            let movedPageId = library.movePage(movedId, to: targetId)
            model.expanded.insert(targetId)
            if let movedPageId, currentPageId == movedId {
                navigator.go(.page(notebookId: targetId, pageId: movedPageId))
            }
            flash(target.id)
        default:
            break
        }
        Haptics.landed()
    }

    private func flash(_ key: String) {
        model.flashedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.sweepRetractMilliseconds)) {
            if model.flashedKey == key {
                model.flashedKey = nil
            }
        }
    }

    private func showMenu(_ entry: ExplorerEntry, at point: CGPoint) {
        let definitions: [Tokens.MenuSlotToken]
        switch entry.kind {
        case .root: definitions = Tokens.shared.menus.explorerRoot
        case .folder: definitions = Tokens.shared.menus.explorerFolder
        case .note: definitions = Tokens.shared.menus.explorerNote
        case .group: return
        }
        let titles = ["rename": "Rename", "new_folder": "New folder", "new_note": "New note", "move": "Move", "delete_notebook": "Delete", "delete_page": "Delete"]
        let isReadOnly = entry.kind == .note && entry.targetId.map { library.isReadOnly($0) } == true
        let slots = MenuSlot.fromTokens(definitions, title: { titles[$0] ?? $0 }, isEnabled: { action in !isReadOnly || action == "delete_page" }) { action in
            perform(action, on: entry)
        }
        menu.present(slots, at: point, title: title(of: entry))
    }

    private func perform(_ action: String, on entry: ExplorerEntry) {
        switch action {
        case "rename":
            beginRename(entry)
        case "new_folder":
            createFolder(in: entry.kind == .folder ? entry.targetId : nil)
        case "new_note":
            if let folderId = entry.targetId {
                createNote(in: folderId)
            }
        case "move":
            withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                model.moving = entry
            }
        case "delete_notebook":
            guard let folderId = entry.targetId else { return }
            let parentId = library.parent(of: folderId)
            let isInside = currentFolderId.map { library.isInside($0, folderId) } ?? false
            library.deleteNotebook(folderId)
            model.expanded.remove(folderId)
            if isInside {
                navigator.go(parentId.map(Route.notebook) ?? .library)
            }
        case "delete_page":
            guard let pageId = entry.targetId else { return }
            let notebookId = library.page(pageId)?.notebook
            library.deletePage(pageId)
            if currentPageId == pageId, let notebookId {
                navigator.go(.notebook(notebookId))
            }
        default:
            break
        }
    }

    private func createFolder(in parentId: String?) {
        let created = library.createNotebook(title: "New folder", parent: parentId)
        if let parentId {
            model.expanded.insert(parentId)
        }
        beginRename(ExplorerEntry(kind: .folder, targetId: created.id, parentId: parentId, groupTitle: nil, depth: 0, guide: ""))
    }

    private func createNote(in notebookId: String) {
        guard library.notebook(notebookId) != nil else { return }
        let created = library.createPage(in: notebookId)
        model.expanded.insert(notebookId)
        beginRename(ExplorerEntry(kind: .note, targetId: created.id, parentId: notebookId, groupTitle: nil, depth: 0, guide: ""))
    }

    private func beginRename(_ entry: ExplorerEntry) {
        finishRename(committing: true)
        model.renameText = title(of: entry)
        model.renamingKey = entry.id
    }

    private func finishRename(committing: Bool) {
        guard let key = model.renamingKey else { return }
        model.renamingKey = nil
        isRenameFocused = false
        let value = model.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard committing, !value.isEmpty else { return }
        if key.hasPrefix("folder-") {
            library.updateNotebook(String(key.dropFirst("folder-".count))) { $0.title = value }
        } else if key.hasPrefix("note-") {
            library.updatePage(String(key.dropFirst("note-".count))) { $0.title = value }
        }
    }

    private func beginDrag(_ entry: ExplorerEntry, at point: CGPoint) {
        menu.dismiss()
        withAnimation(Motion.backOut(Motion.stateMilliseconds)) {
            model.drag = ExplorerDrag(entry: entry, location: point, targetKey: nil)
        }
    }

    private func moveDrag(to point: CGPoint) {
        guard var drag = model.drag else { return }
        drag.location = point
        let all = entries()
        let target = model.rowFrames.first { $0.value.contains(point) }.flatMap { frame in all.first { $0.id == frame.key } }
        let targetKey = target.flatMap { canDrop(drag.entry, on: $0) ? $0.id : nil }
        if targetKey != drag.targetKey {
            if targetKey != nil {
                Haptics.segment()
            }
            model.hoverWork?.cancel()
            if let target, targetKey != nil, target.kind == .folder, let folderId = target.targetId, !model.expanded.contains(folderId) {
                let work = DispatchWorkItem {
                    guard model.drag?.targetKey == target.id else { return }
                    withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds)) {
                        _ = model.expanded.insert(folderId)
                    }
                }
                model.hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandSeconds, execute: work)
            }
        }
        drag.targetKey = targetKey
        model.drag = drag
    }

    private func endDrag(at point: CGPoint, isDropped: Bool) {
        model.hoverWork?.cancel()
        guard let drag = model.drag else { return }
        let target = drag.targetKey.flatMap { key in entries().first { $0.id == key } }
        withAnimation(Motion.powerTwoIn(Motion.stateMilliseconds)) {
            model.drag = nil
        }
        if isDropped, let target {
            perform(move: drag.entry, to: target)
        }
    }
}

private struct ExplorerRowArrival: ViewModifier {
    let isOpen: Bool
    let order: Int

    @State private var isShown = false

    private static let staggeredRows = 24

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(x: isShown ? 0 : 24)
            .onAppear {
                if isOpen {
                    isShown = true
                }
            }
            .onChange(of: isOpen) { _, open in
                guard open else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isShown = false
                }
                DispatchQueue.main.async {
                    withAnimation(Motion.powerTwoOut(Motion.stateMilliseconds, delay: Motion.riseDelayMilliseconds + min(order, Self.staggeredRows) * Motion.explorerRowStaggerMilliseconds)) {
                        isShown = true
                    }
                }
            }
    }
}
