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

@MainActor
final class Library: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var lastError: String?
    @Published var textEditing: TextEditingSession?

    let store: NotesStore
    let sync: SyncCoordinator
    private var undoSteps: [String: [UndoStep]] = [:]
    private var redoSteps: [String: [UndoStep]] = [:]
    private let undoLimit = 200

    init(store: NotesStore) {
        self.store = store
        sync = SyncCoordinator(store: store)
        sync.onStoreChanged = { [weak self] in
            self?.revision += 1
        }
    }

    static func open() -> Library {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VadosNotes")
        do {
            return Library(store: try NotesStore(directory: directory, device: DeviceIdentity.current))
        } catch {
            fatalError("The local notes store cannot be opened: \(error)")
        }
    }

    var device: String { store.device }

    var notebooks: [Notebook] {
        store.liveNotebooks
    }

    func notebook(_ id: String) -> Notebook? {
        store.notebooks[id].flatMap { $0.deleted ? nil : $0 }
    }

    func pages(in notebookId: String) -> [Page] {
        store.livePages(in: notebookId)
    }

    func page(_ id: String) -> Page? {
        store.pages[id].flatMap { $0.deleted ? nil : $0 }
    }

    func isReadOnly(_ pageId: String) -> Bool {
        store.isReadOnly(pageId: pageId)
    }

    @discardableResult
    func createNotebook(title: String) -> Notebook {
        let now = store.timestamp()
        let notebook = Notebook(id: Identifier.make(prefix: Identifier.notebookPrefix, date: now), title: title, updated: now, device: device)
        apply(.notebook(notebook), page: nil)
        createPage(in: notebook.id)
        return notebook
    }

    func rename(_ notebookId: String, to title: String) {
        guard var notebook = notebook(notebookId) else { return }
        notebook.title = title
        notebook.updated = store.timestamp()
        notebook.device = device
        apply(.notebook(notebook), page: nil)
    }

    func deleteNotebook(_ notebookId: String) {
        guard var notebook = notebook(notebookId) else { return }
        for page in pages(in: notebookId) {
            deletePage(page.id)
        }
        notebook.deleted = true
        notebook.updated = store.timestamp()
        notebook.device = device
        apply(.notebook(notebook), page: nil)
    }

    @discardableResult
    func createPage(in notebookId: String) -> Page {
        let now = store.timestamp()
        let header = PageHeader(id: Identifier.make(prefix: Identifier.pagePrefix, date: now), notebook: notebookId, updated: now, device: device)
        apply(.page(header), page: header.id)
        return Page(header: header)
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
        guard var header = page(pageId)?.header, !isReadOnly(pageId) else { return }
        header.extent = columns ? header.extent.doublingColumns() : header.extent.doublingRows()
        header.updated = store.timestamp()
        header.device = device
        apply(.page(header), page: pageId)
    }

    func addStroke(to pageId: String, tool: Tool, color: String, width: Double, points: [Point]) {
        guard let page = page(pageId), !isReadOnly(pageId), !points.isEmpty else { return }
        let now = store.timestamp()
        let element = Element.stroke(
            id: Identifier.make(prefix: Identifier.elementPrefix, date: now),
            tool: tool,
            color: color,
            width: width,
            points: points,
            order: page.nextOrder(in: tool.layer),
            updated: now,
            device: device
        )
        apply(.element(pageId: pageId, element: element), page: pageId)
        record(UndoStep(before: [], after: [element]), on: pageId)
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

    func moveText(_ elementId: String, on pageId: String, to box: TextBox) {
        guard let page = page(pageId), !isReadOnly(pageId), var element = page.element(withId: elementId), !element.deleted else { return }
        let before = element
        element.box = box
        element.updated = store.timestamp()
        element.device = device
        apply(.element(pageId: pageId, element: element), page: pageId)
        record(UndoStep(before: [before], after: [element]), on: pageId)
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
            fontSize: tokens.fontSize,
            color: tokens.color,
            order: page.nextOrder(in: .text),
            updated: now,
            device: device
        )
        textEditing = TextEditingSession(pageId: pageId, element: element, original: nil, isApplied: false)
    }

    func editText(_ elementId: String, on pageId: String) {
        guard let element = page(pageId)?.element(withId: elementId), !element.deleted, !isReadOnly(pageId) else { return }
        finishText()
        textEditing = TextEditingSession(pageId: pageId, element: element, original: element, isApplied: true)
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
        guard session.original?.content != session.element.content else { return }
        record(UndoStep(before: session.original.map { [$0] } ?? [], after: [session.element]), on: session.pageId)
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

    private func revert(_ step: UndoStep, on pageId: String) -> UndoStep {
        guard let page = page(pageId), !isReadOnly(pageId) else { return UndoStep(before: [], after: []) }
        let now = store.timestamp()
        let beforeById = Dictionary(step.before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reverse = UndoStep(before: [], after: [])
        for after in step.after {
            let current = page.element(withId: after.id) ?? after
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
