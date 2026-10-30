import Foundation
import NotesCore

struct UndoStep {
    var before: [Element]
    var after: [Element]
}

struct TextEditingSession: Equatable {
    let pageId: String
    var element: Element
    let original: Element?
    var isApplied: Bool
}

struct StrokeReplacement {
    let elementId: String
    let pieces: [[Point]]
}

struct ImportedDocument {
    let asset: String
    let pages: [[Double]]
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var lastError: String?
    @Published var textEditing: TextEditingSession?

    let store: NotesStore
    let sync: SyncCoordinator
    let assetsDirectory: URL
    private var undoSteps: [String: [UndoStep]] = [:]
    private var redoSteps: [String: [UndoStep]] = [:]
    private let undoLimit = 200
    private let importMargin = 5.0
    private let sizeTolerance = 1.0

    init(store: NotesStore, assetsDirectory: URL) {
        self.store = store
        self.assetsDirectory = assetsDirectory
        sync = SyncCoordinator(store: store)
        sync.onStoreChanged = { [weak self] in
            self?.revision += 1
        }
    }

    static func open() -> Library {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VadosNotes")
        do {
            let assets = directory.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            return Library(store: try NotesStore(directory: directory, device: DeviceIdentity.current), assetsDirectory: assets)
        } catch {
            fatalError("The local notes store cannot be opened: \(error)")
        }
    }

    var device: String { store.device }

    var liveNotebooks: [Notebook] {
        store.liveNotebooks
    }

    func notebook(_ id: String) -> Notebook? {
        store.notebooks[id].flatMap { $0.deleted ? nil : $0 }
    }

    func parent(of notebookId: String) -> String? {
        guard let parent = notebook(notebookId)?.parent, notebook(parent) != nil else { return nil }
        return parent
    }

    func folders(in parentId: String?) -> [Notebook] {
        Arrangement.sorted(liveNotebooks.filter { parent(of: $0.id) == parentId })
    }

    func isInside(_ notebookId: String, _ ancestorId: String) -> Bool {
        var visited: Set<String> = []
        var current: String? = notebookId
        while let candidate = current, !visited.contains(candidate) {
            if candidate == ancestorId {
                return true
            }
            visited.insert(candidate)
            current = parent(of: candidate)
        }
        return false
    }

    func path(of notebookId: String) -> String {
        var names: [String] = []
        var visited: Set<String> = []
        var current: String? = notebookId
        while let candidate = current, !visited.contains(candidate) {
            visited.insert(candidate)
            names.insert(notebook(candidate)?.title ?? "", at: 0)
            current = parent(of: candidate)
        }
        return names.joined(separator: " / ")
    }

    func pages(in notebookId: String) -> [Page] {
        Arrangement.sorted(store.livePages(in: notebookId))
    }

    func page(_ id: String) -> Page? {
        store.pages[id].flatMap { $0.deleted ? nil : $0 }
    }

    func noteTitle(_ page: Page) -> String {
        if let title = page.title {
            return title
        }
        let index = pages(in: page.notebook).firstIndex { $0.id == page.id } ?? 0
        return "Note \(index + 1)"
    }

    func isReadOnly(_ pageId: String) -> Bool {
        store.isReadOnly(pageId: pageId)
    }

    @discardableResult
    func createNotebook(title: String, parent parentId: String?) -> Notebook {
        let now = store.timestamp()
        let validParent = parentId.flatMap { notebook($0) == nil ? nil : $0 }
        let created = Notebook(
            id: Identifier.make(prefix: Identifier.notebookPrefix, date: now),
            title: title,
            updated: now,
            device: device,
            parent: validParent,
            order: Arrangement.endOrder(after: folders(in: validParent))
        )
        apply(.notebook(created), page: nil)
        return created
    }

    func updateNotebook(_ notebookId: String, _ change: (inout Notebook) -> Void) {
        guard var notebook = notebook(notebookId) else { return }
        change(&notebook)
        notebook.updated = store.timestamp()
        notebook.device = device
        apply(.notebook(notebook), page: nil)
    }

    func canMoveNotebook(_ notebookId: String, into parentId: String?) -> Bool {
        guard notebook(notebookId) != nil else { return false }
        guard let parentId else { return true }
        return notebook(parentId) != nil && !isInside(parentId, notebookId)
    }

    func moveNotebook(_ notebookId: String, into parentId: String?) {
        guard canMoveNotebook(notebookId, into: parentId), parent(of: notebookId) != parentId else { return }
        let order = Arrangement.endOrder(after: folders(in: parentId))
        updateNotebook(notebookId) { notebook in
            notebook.parent = parentId
            notebook.order = order
        }
    }

    func deleteNotebook(_ notebookId: String) {
        guard notebook(notebookId) != nil else { return }
        for child in folders(in: notebookId) {
            deleteNotebook(child.id)
        }
        for page in pages(in: notebookId) {
            deletePage(page.id)
        }
        updateNotebook(notebookId) { $0.deleted = true }
    }

    func arrangeFolders(_ identifiers: [String]) {
        for (index, identifier) in identifiers.enumerated() where notebook(identifier)?.order != index {
            updateNotebook(identifier) { $0.order = index }
        }
    }

    func arrangePages(_ identifiers: [String]) {
        for (index, identifier) in identifiers.enumerated() where page(identifier)?.order != index {
            updatePage(identifier) { $0.order = index }
        }
    }

    @discardableResult
    func createPage(in notebookId: String, title: String? = nil, document: ImportedDocument? = nil) -> Page {
        let now = store.timestamp()
        let siblings = pages(in: notebookId)
        let header = PageHeader(
            id: Identifier.make(prefix: Identifier.pagePrefix, date: now),
            notebook: notebookId,
            updated: now,
            device: device,
            extent: Extent(columns: 1, rows: max(1, document?.pages.count ?? 1)),
            title: title ?? "Note \(siblings.count + 1)",
            order: Arrangement.endOrder(after: siblings)
        )
        apply(.page(header), page: header.id)
        if let document {
            for (index, size) in document.pages.enumerated() {
                apply(.element(pageId: header.id, element: importElement(asset: document.asset, index: index, size: size, now: now)), page: header.id)
            }
        }
        return page(header.id) ?? Page(header: header)
    }

    func appendDocument(_ document: ImportedDocument, to pageId: String) {
        guard let page = page(pageId), !isReadOnly(pageId), !document.pages.isEmpty else { return }
        let now = store.timestamp()
        let firstRow = page.extent.rows
        let firstOrder = (page.elements.map(\.order).max() ?? -1) + 1
        updatePage(pageId) { header in
            header.extent = Extent(columns: header.extent.columns, rows: firstRow + document.pages.count)
        }
        for (index, size) in document.pages.enumerated() {
            var element = importElement(asset: document.asset, index: index, size: size, now: now, row: firstRow + index)
            element.order = firstOrder + index
            apply(.element(pageId: pageId, element: element), page: pageId)
        }
    }

    private func importElement(asset: String, index: Int, size: [Double], now: Date, row: Int? = nil) -> Element {
        let width = size[0]
        let height = size[1]
        let cellWidth = PaperGeometry.cellWidth
        let cellHeight = PaperGeometry.cellHeight
        let isA4 = abs(width - cellWidth) <= sizeTolerance && abs(height - cellHeight) <= sizeTolerance
        let scale = isA4 ? 1 : min((cellWidth - importMargin * 2) / width, (cellHeight - importMargin * 2) / height)
        func rounded(_ value: Double) -> Double {
            (value * 100).rounded() / 100
        }
        return Element(
            id: Identifier.make(prefix: Identifier.elementPrefix, date: now),
            type: .importPage,
            layer: .importLayer,
            order: index,
            asset: asset,
            sourcePage: index,
            sourceSizeMillimetres: [width, height],
            placement: Placement(x: rounded((cellWidth - width * scale) / 2), y: rounded(Double(row ?? index) * cellHeight + (cellHeight - height * scale) / 2), scale: (scale * 10000).rounded() / 10000),
            fit: isA4 ? .original : .fitCell,
            updated: now,
            device: device
        )
    }

    func updatePage(_ pageId: String, _ change: (inout PageHeader) -> Void) {
        guard var header = page(pageId)?.header, !isReadOnly(pageId) else { return }
        change(&header)
        header.updated = store.timestamp()
        header.device = device
        apply(.page(header), page: pageId)
    }

    @discardableResult
    func movePage(_ pageId: String, to notebookId: String) -> String? {
        guard let source = page(pageId), !isReadOnly(pageId), source.notebook != notebookId, notebook(notebookId) != nil else { return nil }
        finishText()
        let now = store.timestamp()
        var header = source.header
        header.id = Identifier.make(prefix: Identifier.pagePrefix, date: now)
        header.notebook = notebookId
        header.order = Arrangement.endOrder(after: pages(in: notebookId))
        header.updated = now
        header.device = device
        apply(.page(header), page: header.id)
        for element in source.elements {
            apply(.element(pageId: header.id, element: element), page: header.id)
        }
        deletePage(pageId)
        return header.id
    }

    func deletePage(_ pageId: String) {
        guard var header = page(pageId)?.header else { return }
        header.deleted = true
        header.updated = store.timestamp()
        header.device = device
        apply(.page(header), page: pageId)
        undoSteps[pageId] = nil
        redoSteps[pageId] = nil
    }

    func expand(_ pageId: String, columns: Bool) {
        updatePage(pageId) { header in
            header.extent = columns ? header.extent.doublingColumns() : header.extent.doublingRows()
        }
    }

    func addStrokes(to pageId: String, tool: Tool, color: String, width: Double, pieces: [[Point]]) {
        let shown = pieces.filter { !$0.isEmpty }
        guard page(pageId) != nil, !isReadOnly(pageId), !shown.isEmpty else { return }
        let now = store.timestamp()
        var added: [Element] = []
        for points in shown {
            guard let current = page(pageId) else { return }
            let element = Element.stroke(
                id: Identifier.make(prefix: Identifier.elementPrefix, date: now),
                tool: tool,
                color: color,
                width: width,
                points: points,
                order: current.nextOrder(in: tool.layer),
                updated: now,
                device: device
            )
            apply(.element(pageId: pageId, element: element), page: pageId)
            added.append(element)
        }
        record(UndoStep(before: [], after: added), on: pageId)
    }

    func erase(_ elementIds: [String], on pageId: String) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        for id in elementIds {
            guard let element = page.element(withId: id), !element.deleted else { continue }
            let tombstone = element.tombstone(at: now, device: device)
            apply(.element(pageId: pageId, element: tombstone), page: pageId)
            step.before.append(element)
            step.after.append(tombstone)
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func replaceStrokes(on pageId: String, _ replacements: [StrokeReplacement]) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        for replacement in replacements {
            guard let element = page.element(withId: replacement.elementId), !element.deleted else { continue }
            let tombstone = element.tombstone(at: now, device: device)
            apply(.element(pageId: pageId, element: tombstone), page: pageId)
            step.before.append(element)
            step.after.append(tombstone)
            for points in replacement.pieces {
                var piece = element
                piece.id = Identifier.make(prefix: Identifier.elementPrefix, date: now)
                piece.points = points
                piece.updated = now
                piece.device = device
                piece.deleted = false
                apply(.element(pageId: pageId, element: piece), page: pageId)
                step.after.append(piece)
            }
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func moveText(_ elementId: String, on pageId: String, to box: TextBox) {
        guard let page = page(pageId), !isReadOnly(pageId), var element = page.element(withId: elementId), !element.deleted else { return }
        let before = element
        element.box = box
        element = TextRhythm.fitted(element, extent: page.extent)
        element.updated = store.timestamp()
        element.device = device
        apply(.element(pageId: pageId, element: element), page: pageId)
        record(UndoStep(before: [before], after: [element]), on: pageId)
    }

    func moveElements(_ elementIds: [String], on pageId: String, by offset: Point) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        for id in elementIds {
            guard let element = page.element(withId: id), !element.deleted else { continue }
            var moved = TextRhythm.fitted(Lasso.translated(element, by: offset), extent: page.extent)
            moved.updated = now
            moved.device = device
            apply(.element(pageId: pageId, element: moved), page: pageId)
            step.before.append(element)
            step.after.append(moved)
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func scaleElements(_ elementIds: [String], on pageId: String, about anchor: Point, by factor: Double) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        for id in elementIds {
            guard let element = page.element(withId: id), !element.deleted else { continue }
            var scaled = TextRhythm.fitted(Lasso.scaled(element, about: anchor, by: factor), extent: page.extent)
            scaled.updated = now
            scaled.device = device
            apply(.element(pageId: pageId, element: scaled), page: pageId)
            step.before.append(element)
            step.after.append(scaled)
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func setStrokeWidth(_ elementIds: [String], on pageId: String, to width: Double) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        for id in elementIds {
            guard let element = page.element(withId: id), !element.deleted, element.type == .stroke, element.width != width else { continue }
            var resized = element
            resized.width = width
            resized.updated = now
            resized.device = device
            apply(.element(pageId: pageId, element: resized), page: pageId)
            step.before.append(element)
            step.after.append(resized)
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func placeText(_ box: TextBox) {
        guard var session = textEditing, session.element.box != box else { return }
        session.element.box = box
        session.element.updated = store.timestamp()
        session.element.device = device
        if session.isApplied {
            apply(.element(pageId: session.pageId, element: session.element), page: session.pageId)
        }
        textEditing = session
    }

    func beginText(on pageId: String, at point: Point) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        finishText()
        let tokens = Tokens.shared.text
        let now = store.timestamp()
        let element = Element.text(
            id: Identifier.make(prefix: Identifier.elementPrefix, date: now),
            content: "",
            box: TextBox(x: point.x, y: point.y, width: tokens.boxWidth),
            fontSize: Double(TextRhythm.fontSize),
            color: tokens.color,
            order: page.nextOrder(in: .text),
            updated: now,
            device: device
        )
        textEditing = TextEditingSession(pageId: pageId, element: element, original: nil, isApplied: false)
    }

    func editText(_ elementId: String, on pageId: String) {
        guard let page = page(pageId), let element = page.element(withId: elementId), !element.deleted, !isReadOnly(pageId) else { return }
        finishText()
        var fitted = TextRhythm.fitted(element, extent: page.extent)
        if fitted != element {
            fitted.updated = store.timestamp()
            fitted.device = device
            apply(.element(pageId: pageId, element: fitted), page: pageId)
        }
        textEditing = TextEditingSession(pageId: pageId, element: fitted, original: element, isApplied: true)
    }

    func updateText(_ content: String) {
        guard var session = textEditing, session.element.content != content else { return }
        session.element.content = content
        session.element.updated = store.timestamp()
        session.element.device = device
        if session.isApplied || !content.isEmpty {
            apply(.element(pageId: session.pageId, element: session.element), page: session.pageId)
            session.isApplied = true
        }
        textEditing = session
    }

    func styleText(color: String? = nil) {
        guard var session = textEditing else { return }
        if let color {
            session.element.color = color
        }
        session.element.updated = store.timestamp()
        session.element.device = device
        if session.isApplied {
            apply(.element(pageId: session.pageId, element: session.element), page: session.pageId)
        }
        textEditing = session
    }

    func finishText() {
        guard let session = textEditing else { return }
        textEditing = nil
        guard session.isApplied else { return }
        let isEmpty = (session.element.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            let tombstone = session.element.tombstone(at: store.timestamp(), device: device)
            apply(.element(pageId: session.pageId, element: tombstone), page: session.pageId)
            if let original = session.original {
                record(UndoStep(before: [original], after: [tombstone]), on: session.pageId)
            }
            return
        }
        let original = session.original
        let isChanged = original?.content != session.element.content || original?.fontSize != session.element.fontSize || original?.color != session.element.color || original?.box != session.element.box
        guard isChanged else { return }
        record(UndoStep(before: original.map { [$0] } ?? [], after: [session.element]), on: session.pageId)
    }

    func canUndo(_ pageId: String) -> Bool {
        !(undoSteps[pageId] ?? []).isEmpty
    }

    func canRedo(_ pageId: String) -> Bool {
        !(redoSteps[pageId] ?? []).isEmpty
    }

    func undo(_ pageId: String) {
        finishText()
        guard let step = undoSteps[pageId]?.popLast() else { return }
        let reverse = revert(step, on: pageId)
        redoSteps[pageId, default: []].append(reverse)
        revision += 1
    }

    func redo(_ pageId: String) {
        finishText()
        guard let step = redoSteps[pageId]?.popLast() else { return }
        let reverse = revert(step, on: pageId)
        undoSteps[pageId, default: []].append(reverse)
        revision += 1
    }

    func noteInput(on pageId: String) {
        sync.recordInput(page: pageId)
    }

    func assetURL(_ asset: String) -> URL {
        assetsDirectory.appendingPathComponent("\(asset.replacingOccurrences(of: "sha256:", with: "")).pdf")
    }

    private func revert(_ step: UndoStep, on pageId: String) -> UndoStep {
        guard page(pageId) != nil, !isReadOnly(pageId) else { return UndoStep(before: [], after: []) }
        let now = store.timestamp()
        let beforeById = Dictionary(step.before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reverse = UndoStep(before: [], after: [])
        for after in step.after {
            let current = page(pageId)?.element(withId: after.id) ?? after
            if let before = beforeById[after.id] {
                if after.deleted && !before.deleted {
                    var revived = before
                    revived.id = Identifier.make(prefix: Identifier.elementPrefix, date: now)
                    revived.updated = now
                    revived.device = device
                    revived.deleted = false
                    apply(.element(pageId: pageId, element: revived), page: pageId)
                    reverse.after.append(revived)
                } else if !after.deleted {
                    var restored = before
                    restored.updated = now
                    restored.device = device
                    apply(.element(pageId: pageId, element: restored), page: pageId)
                    reverse.before.append(current)
                    reverse.after.append(restored)
                }
            } else if !current.deleted {
                let tombstone = current.tombstone(at: now, device: device)
                apply(.element(pageId: pageId, element: tombstone), page: pageId)
                reverse.before.append(current)
                reverse.after.append(tombstone)
            }
        }
        return reverse
    }

    private func record(_ step: UndoStep, on pageId: String) {
        var steps = undoSteps[pageId] ?? []
        steps.append(step)
        if steps.count > undoLimit {
            steps.removeFirst(steps.count - undoLimit)
        }
        undoSteps[pageId] = steps
        redoSteps[pageId] = []
    }

    private func apply(_ change: Change, page pageId: String?) {
        do {
            try store.apply(change)
            sync.recordChange(page: pageId ?? "library")
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        revision += 1
    }
}
