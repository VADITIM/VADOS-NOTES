import CoreGraphics
import Foundation
import NotesCore
import UIKit

struct ExtentChange {
    let before: Extent
    let after: Extent
}

struct UndoStep {
    var before: [Element]
    var after: [Element]
    var extent: ExtentChange? = nil
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
    let name: String?
    let pages: [[Double]]
    var inverted: [Bool]

    func isInverted(_ index: Int) -> Bool {
        inverted.indices.contains(index) && inverted[index]
    }
}

struct CellPosition: Hashable {
    let column: Int
    let row: Int

    static func readingOrder(_ first: CellPosition, _ second: CellPosition) -> Bool {
        first.row != second.row ? first.row < second.row : first.column < second.column
    }
}

struct PagePlacement: Hashable {
    let cell: CellPosition
    let index: Int
}

struct TileGroup: Equatable, Identifiable {
    var id: String
    var title: String
    var isFolders: Bool
    var members: [String]
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var lastError: String?
    @Published var textEditing: TextEditingSession?
    @Published private(set) var clipboard: [Element] = []

    let store: NotesStore
    let sync: SyncCoordinator
    private var undoSteps: [String: [UndoStep]] = [:]
    private var redoSteps: [String: [UndoStep]] = [:]
    private var openPageId: String?
    private var memoryObserver: NSObjectProtocol?
    private let importMargin = 5.0
    private let sizeTolerance = 1.0
    private let duplicateOffset = 8.0

    init(store: NotesStore) {
        self.store = store
        sync = SyncCoordinator(store: store)
        sync.onStoreChanged = { [weak self] in
            self?.revision += 1
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseMemory()
            }
        }
        compactJournal()
    }

    private var undoLimit: Int {
        Tokens.shared.memory.undoSteps
    }

    func noteOpened(_ pageId: String) {
        openPageId = pageId
    }

    func noteClosed(_ pageId: String) {
        if openPageId == pageId {
            openPageId = nil
        }
        undoSteps[pageId] = nil
        redoSteps[pageId] = nil
        compactJournal()
    }

    private func releaseMemory() {
        undoSteps = undoSteps.filter { $0.key == openPageId }
        redoSteps = redoSteps.filter { $0.key == openPageId }
        compactJournal()
    }

    private func compactJournal() {
        guard !sync.isRunning else { return }
        do {
            try store.compactJournal(above: Tokens.shared.memory.journalCompactEntries)
        } catch {
            lastError = String(describing: error)
        }
    }

    static func open() -> Library {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VadosNotes")
        do {
            return Library(store: try NotesStore(directory: directory, device: DeviceIdentity.current, assetByteLimit: Tokens.shared.sync.assetByteLimit))
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
            notebook.group = nil
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
            grouped {
                for (index, size) in document.pages.enumerated() {
                    apply(.element(pageId: header.id, element: importElement(asset: document.asset, index: index, size: size, now: now, isInverted: document.isInverted(index), sourceName: document.name)), page: header.id)
                }
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
        grouped {
            for (index, size) in document.pages.enumerated() {
                var element = importElement(asset: document.asset, index: index, size: size, now: now, row: firstRow + index, isInverted: document.isInverted(index), sourceName: document.name)
                element.order = firstOrder + index
                apply(.element(pageId: pageId, element: element), page: pageId)
            }
        }
    }

    func placeDocument(_ document: ImportedDocument, to pageId: String, placements: [PagePlacement]) {
        let placements = placements.filter { $0.index < document.pages.count }.sorted { $0.index < $1.index }
        let cells = placements.map(\.cell)
        guard let page = page(pageId), !isReadOnly(pageId), !cells.isEmpty else { return }
        let now = store.timestamp()
        let firstOrder = (page.elements.map(\.order).max() ?? -1) + 1
        let columns = max(page.extent.columns, (cells.map(\.column).max() ?? 0) + 1)
        let rows = max(page.extent.rows, (cells.map(\.row).max() ?? 0) + 1)
        if columns != page.extent.columns || rows != page.extent.rows {
            updatePage(pageId) { header in
                header.extent = Extent(columns: columns, rows: rows)
            }
        }
        grouped {
            for (position, placement) in placements.enumerated() {
                var element = importElement(asset: document.asset, index: placement.index, size: document.pages[placement.index], now: now, row: placement.cell.row, column: placement.cell.column, isInverted: document.isInverted(placement.index), sourceName: document.name)
                element.order = firstOrder + position
                apply(.element(pageId: pageId, element: element), page: pageId)
            }
        }
    }

    func placeImportPage(asset: String, sourcePage: Int, size: [Double], sourceName: String?, isInverted: Bool, on pageId: String, at cell: CellPosition) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        finishText()
        let now = store.timestamp()
        let edit = ImportPlacing.placed(asset: asset, sourcePage: sourcePage, at: CellIndex(column: cell.column, row: cell.row), in: page.elements, now: now, device: device) {
            var element = importElement(asset: asset, index: sourcePage, size: size, now: now, row: cell.row, column: cell.column, isInverted: isInverted, sourceName: sourceName)
            element.order = page.nextOrder(in: .importLayer)
            return element
        }
        guard !edit.after.isEmpty else { return }
        grouped {
            for element in edit.after {
                apply(.element(pageId: pageId, element: element), page: pageId)
            }
        }
        record(UndoStep(before: edit.before, after: edit.after), on: pageId)
    }

    func importElement(asset: String, index: Int, size: [Double], now: Date, row: Int? = nil, column: Int = 0, isInverted: Bool = false, sourceName: String? = nil) -> Element {
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
            sourceName: sourceName,
            sourceSizeMillimetres: [width, height],
            placement: Placement(x: rounded(Double(column) * cellWidth + (cellWidth - width * scale) / 2), y: rounded(Double(row ?? index) * cellHeight + (cellHeight - height * scale) / 2), scale: (scale * 10000).rounded() / 10000),
            fit: isA4 ? .original : .fitCell,
            inverted: isInverted,
            updated: now,
            device: device
        )
    }

    func updatePage(_ pageId: String, _ change: (inout PageHeader) -> Void) {
        guard var header = page(pageId)?.header, !isReadOnly(pageId) else { return }
        let extent = header.extent
        change(&header)
        header.updated = store.timestamp()
        if header.extent != extent {
            header.extentUpdated = header.updated
        }
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
        header.group = nil
        header.updated = now
        header.device = device
        apply(.page(header), page: header.id)
        grouped {
            for element in source.elements {
                apply(.element(pageId: header.id, element: element), page: header.id)
            }
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
            header.extent = columns ? header.extent.addingColumn() : header.extent.addingRow()
        }
    }

    func swapCells(_ pageId: String, _ first: CellPosition, _ second: CellPosition) {
        guard let page = page(pageId), !isReadOnly(pageId), first != second else { return }
        finishText()
        let now = store.timestamp()
        let moved = CellSwap.moved(page.liveElements, swapping: CellIndex(column: first.column, row: first.row), with: CellIndex(column: second.column, row: second.row)) { element in
            Self.elementBounds(element).map { Point(x: Double($0.midX), y: Double($0.midY)) }
        }
        guard !moved.isEmpty else { return }
        var step = UndoStep(before: [], after: [])
        grouped {
            for element in moved {
                guard let original = page.element(withId: element.id) else { continue }
                var shifted = element
                shifted.updated = now
                shifted.device = device
                apply(.element(pageId: pageId, element: shifted), page: pageId)
                step.before.append(original)
                step.after.append(shifted)
            }
        }
        record(step, on: pageId)
    }

    func filledCells(of pageId: String) -> Set<CellPosition> {
        guard let page = page(pageId) else { return [] }
        return Set(page.liveElements.compactMap { Self.elementBounds($0).map(Self.cell(holding:)) })
    }

    func clearCells(_ cells: Set<CellPosition>, on pageId: String) {
        guard let page = page(pageId), !isReadOnly(pageId), !cells.isEmpty else { return }
        finishText()
        let ids = page.liveElements.filter { element in
            Self.elementBounds(element).map { cells.contains(Self.cell(holding: $0)) } ?? false
        }.map(\.id)
        erase(ids, on: pageId)
    }

    private static func cell(holding bounds: CGRect) -> CellPosition {
        CellPosition(column: Int((Double(bounds.midX) / PaperGeometry.cellWidth).rounded(.down)), row: Int((Double(bounds.midY) / PaperGeometry.cellHeight).rounded(.down)))
    }

    func removeCell(_ pageId: String, along axis: CellAxis, at index: Int) {
        guard let page = page(pageId), !isReadOnly(pageId), page.extent.count(along: axis) > 1 else { return }
        finishText()
        let now = store.timestamp()
        let outcome = CellRemoval.outcome(of: page.liveElements, removing: index, along: axis) { element in
            Self.elementBounds(element).map { Point(x: Double($0.midX), y: Double($0.midY)) }
        }
        var step = UndoStep(before: [], after: [], extent: ExtentChange(before: page.extent, after: page.extent.removing(axis)))
        grouped {
            for element in outcome.removed {
                let tombstone = element.tombstone(at: now, device: device)
                apply(.element(pageId: pageId, element: tombstone), page: pageId)
                step.before.append(element)
                step.after.append(tombstone)
            }
        }
        grouped {
            for moved in outcome.moved {
                guard let original = page.element(withId: moved.id) else { continue }
                var shifted = moved
                shifted.updated = now
                shifted.device = device
                apply(.element(pageId: pageId, element: shifted), page: pageId)
                step.before.append(original)
                step.after.append(shifted)
            }
        }
        setExtent(page.extent.removing(axis), of: pageId)
        record(step, on: pageId)
    }

    func copyElements(_ elementIds: [String], on pageId: String) {
        guard let page = page(pageId) else { return }
        clipboard = page.liveElements.filter { elementIds.contains($0.id) }
    }

    func cutElements(_ elementIds: [String], on pageId: String) {
        copyElements(elementIds, on: pageId)
        erase(elementIds, on: pageId)
    }

    @discardableResult
    func paste(on pageId: String, centredAt centre: Point) -> [String] {
        guard let bounds = Self.bounds(of: clipboard) else { return [] }
        let offset = Point(x: centre.x - Double(bounds.midX), y: centre.y - Double(bounds.midY))
        return place(clipboard, on: pageId, by: offset)
    }

    @discardableResult
    func duplicate(_ elementIds: [String], on pageId: String) -> [String] {
        guard let page = page(pageId) else { return [] }
        return place(page.liveElements.filter { elementIds.contains($0.id) }, on: pageId, by: Point(x: duplicateOffset, y: duplicateOffset))
    }

    func setColor(_ elementIds: [String], on pageId: String, to color: String) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        grouped {
            for id in elementIds {
                guard let element = page.element(withId: id), !element.deleted, element.type != .importPage, element.color != color else { continue }
                var recolored = element
                recolored.color = color
                recolored.updated = now
                recolored.device = device
                apply(.element(pageId: pageId, element: recolored), page: pageId)
                step.before.append(element)
                step.after.append(recolored)
            }
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func setInverted(_ elementIds: [String], on pageId: String, to isInverted: Bool) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        grouped {
            for id in elementIds {
                guard let element = page.element(withId: id), !element.deleted, element.type == .importPage, element.inverted != isInverted else { continue }
                var changed = element
                changed.inverted = isInverted
                changed.updated = now
                changed.device = device
                apply(.element(pageId: pageId, element: changed), page: pageId)
                step.before.append(element)
                step.after.append(changed)
            }
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    private func place(_ elements: [Element], on pageId: String, by offset: Point) -> [String] {
        guard page(pageId) != nil, !isReadOnly(pageId), !elements.isEmpty else { return [] }
        finishText()
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        grouped {
            for element in elements.sorted(by: Element.isOrderedBefore) {
                guard let current = page(pageId) else { break }
                var copy = Lasso.translated(element, by: offset)
                copy.id = Identifier.make(prefix: Identifier.elementPrefix, date: now)
                copy.order = current.nextOrder(in: element.layer)
                copy.updated = now
                copy.device = device
                copy.deleted = false
                apply(.element(pageId: pageId, element: copy), page: pageId)
                step.after.append(copy)
            }
        }
        record(step, on: pageId)
        return step.after.map(\.id)
    }

    private func setExtent(_ extent: Extent, of pageId: String) {
        updatePage(pageId) { header in
            header.extent = extent
        }
    }

    static func elementBounds(_ element: Element) -> CGRect? {
        InkCanvasView.elementBounds(element)
    }

    static func bounds(of elements: [Element]) -> CGRect? {
        elements.compactMap(elementBounds).reduce(CGRect?.none) { union, rect in union.map { $0.union(rect) } ?? rect }
    }

    func addStrokes(to pageId: String, tool: Tool, color: String, width: Double, pieces: [[Point]]) {
        let shown = pieces.filter { !$0.isEmpty }
        guard page(pageId) != nil, !isReadOnly(pageId), !shown.isEmpty else { return }
        let now = store.timestamp()
        var added: [Element] = []
        grouped {
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
        }
        record(UndoStep(before: [], after: added), on: pageId)
    }

    func erase(_ elementIds: [String], on pageId: String) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        grouped {
            for id in elementIds {
                guard let element = page.element(withId: id), !element.deleted else { continue }
                let tombstone = element.tombstone(at: now, device: device)
                apply(.element(pageId: pageId, element: tombstone), page: pageId)
                step.before.append(element)
                step.after.append(tombstone)
            }
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func replaceStrokes(on pageId: String, _ replacements: [StrokeReplacement]) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        grouped {
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
        grouped {
            for id in elementIds {
                guard let element = page.element(withId: id), !element.deleted else { continue }
                var moved = TextRhythm.fitted(Lasso.translated(element, by: offset), extent: page.extent)
                moved.updated = now
                moved.device = device
                apply(.element(pageId: pageId, element: moved), page: pageId)
                step.before.append(element)
                step.after.append(moved)
            }
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func scaleElements(_ elementIds: [String], on pageId: String, about anchor: Point, by factor: Double) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        grouped {
            for id in elementIds {
                guard let element = page.element(withId: id), !element.deleted else { continue }
                var scaled = TextRhythm.fitted(Lasso.scaled(element, about: anchor, by: factor), extent: page.extent)
                scaled.updated = now
                scaled.device = device
                apply(.element(pageId: pageId, element: scaled), page: pageId)
                step.before.append(element)
                step.after.append(scaled)
            }
        }
        if !step.after.isEmpty {
            record(step, on: pageId)
        }
    }

    func setStrokeWidth(_ elementIds: [String], on pageId: String, to width: Double) {
        guard let page = page(pageId), !isReadOnly(pageId) else { return }
        let now = store.timestamp()
        var step = UndoStep(before: [], after: [])
        grouped {
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

    func assetURL(_ asset: String) -> URL? {
        store.assets.fileURL(for: asset)
    }

    private func revert(_ step: UndoStep, on pageId: String) -> UndoStep {
        guard page(pageId) != nil, !isReadOnly(pageId) else { return UndoStep(before: [], after: []) }
        let now = store.timestamp()
        let edit = ElementEdit(before: step.before, after: step.after).reversal(current: { page(pageId)?.element(withId: $0) }, now: now, device: device) {
            Identifier.make(prefix: Identifier.elementPrefix, date: now)
        }
        var reverse = UndoStep(before: edit.before, after: edit.after)
        grouped {
            for element in edit.after {
                apply(.element(pageId: pageId, element: element), page: pageId)
            }
        }
        if let change = step.extent {
            setExtent(change.before, of: pageId)
            reverse.extent = ExtentChange(before: change.after, after: change.before)
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

    private func grouped(_ work: () -> Void) {
        do {
            try store.journal.grouped(work)
        } catch {
            lastError = String(describing: error)
        }
    }

    func groups(in parentId: String?) -> [TileGroup] {
        let records = store.liveGroups(in: parentId).enumerated().sorted { first, second in
            (first.element.order ?? first.offset, first.element.id) < (second.element.order ?? second.offset, second.element.id)
        }.map(\.element)
        return records.map { record in
            TileGroup(id: record.id, title: record.title, isFolders: record.kind == .folders, members: members(of: record, in: parentId))
        }.filter { !$0.members.isEmpty }
    }

    private func members(of record: GroupRecord, in parentId: String?) -> [String] {
        if record.kind == .folders {
            return folders(in: parentId).filter { $0.group == record.id }.map(\.id)
        }
        guard let parentId else { return [] }
        return pages(in: parentId).filter { $0.group == record.id }.map(\.id)
    }

    private func setGroup(_ groupId: String?, of memberId: String) {
        if notebook(memberId) != nil {
            updateNotebook(memberId) { $0.group = groupId }
        } else if page(memberId) != nil {
            updatePage(memberId) { $0.group = groupId }
        }
    }

    private func updateGroup(_ groupId: String, _ change: (inout GroupRecord) -> Void) {
        guard var group = store.groups[groupId], !group.deleted else { return }
        change(&group)
        group.updated = store.timestamp()
        group.device = device
        apply(.group(group), page: nil)
    }

    func addToGroup(_ memberId: String, groupId: String, in parentId: String?) {
        guard store.groups[groupId]?.deleted == false else { return }
        let previous = groups(in: parentId).first { $0.members.contains(memberId) }
        setGroup(groupId, of: memberId)
        if let previous, previous.id != groupId, previous.members == [memberId] {
            updateGroup(previous.id) { $0.deleted = true }
        }
    }

    @discardableResult
    func createGroup(_ title: String, isFolders: Bool, with memberId: String, in parentId: String?) -> String {
        let now = store.timestamp()
        let order = (store.liveGroups(in: parentId).compactMap(\.order).max() ?? -1) + 1
        let group = GroupRecord(id: Identifier.make(prefix: Identifier.groupPrefix, date: now), parent: parentId, title: title, kind: isFolders ? .folders : .notes, order: order, updated: now, device: device)
        apply(.group(group), page: nil)
        addToGroup(memberId, groupId: group.id, in: parentId)
        return group.id
    }

    func removeFromGroup(_ memberId: String, in parentId: String?) {
        guard let group = groups(in: parentId).first(where: { $0.members.contains(memberId) }) else { return }
        setGroup(nil, of: memberId)
        if group.members == [memberId] {
            updateGroup(group.id) { $0.deleted = true }
        }
    }

    func renameGroup(_ groupId: String, to title: String) {
        updateGroup(groupId) { $0.title = title }
    }

    func ungroup(_ groupId: String) {
        updateGroup(groupId) { $0.deleted = true }
    }

    func adoptDeviceGroups(_ taken: [(parentId: String?, groups: [DeviceGroup])]) {
        for (parentId, deviceGroups) in taken {
            for deviceGroup in deviceGroups {
                let live = deviceGroup.members.filter { id in
                    deviceGroup.isFolders ? notebook(id) != nil && parent(of: id) == parentId : parentId != nil && page(id)?.notebook == parentId
                }
                guard let first = live.first else { continue }
                let groupId = createGroup(deviceGroup.title, isFolders: deviceGroup.isFolders, with: first, in: parentId)
                for memberId in live.dropFirst() {
                    setGroup(groupId, of: memberId)
                }
            }
        }
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
