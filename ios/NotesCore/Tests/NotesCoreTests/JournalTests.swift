import XCTest
@testable import NotesCore

final class JournalTests: XCTestCase {
    func testEntriesSurviveReopening() throws {
        let url = Fixtures.temporaryDirectory().appendingPathComponent("journal.jsonl")
        let journal = try Journal(fileURL: url)
        try journal.append(.element(pageId: "p_01TEST", element: Fixtures.stroke("e_A")), device: "ipad-01", timestamp: Fixtures.time(0))
        try journal.append(.element(pageId: "p_01TEST", element: Fixtures.stroke("e_B")), device: "ipad-01", timestamp: Fixtures.time(1))

        let reopened = try Journal(fileURL: url)

        XCTAssertEqual(reopened.entries, journal.entries)
        XCTAssertEqual(reopened.entries.map(\.sequence), [1, 2])
    }

    func testGroupedEntriesAreWrittenTogether() throws {
        let url = Fixtures.temporaryDirectory().appendingPathComponent("journal.jsonl")
        let journal = try Journal(fileURL: url)
        try journal.grouped {
            for index in 0..<3 {
                _ = try? journal.append(.element(pageId: "p_01TEST", element: Fixtures.stroke("e_\(index)")), device: "ipad-01", timestamp: Fixtures.time(Double(index)))
            }
            XCTAssertEqual((try? Journal(fileURL: url))?.entries.count, 0)
        }

        let reopened = try Journal(fileURL: url)

        XCTAssertEqual(reopened.entries.map(\.sequence), [1, 2, 3])
    }

    func testRemovingSyncedEntriesKeepsTheRest() throws {
        let url = Fixtures.temporaryDirectory().appendingPathComponent("journal.jsonl")
        let journal = try Journal(fileURL: url)
        for index in 0..<4 {
            try journal.append(.element(pageId: "p_01TEST", element: Fixtures.stroke("e_\(index)")), device: "ipad-01", timestamp: Fixtures.time(Double(index)))
        }

        try journal.remove(sequences: [1, 2, 4])
        try journal.append(.element(pageId: "p_01TEST", element: Fixtures.stroke("e_LATE")), device: "ipad-01", timestamp: Fixtures.time(9))
        let reopened = try Journal(fileURL: url)

        XCTAssertEqual(reopened.entries.map(\.sequence), [3, 5])
    }

    func testTornLastLineIsSkipped() throws {
        let url = Fixtures.temporaryDirectory().appendingPathComponent("journal.jsonl")
        let journal = try Journal(fileURL: url)
        try journal.append(.element(pageId: "p_01TEST", element: Fixtures.stroke("e_A")), device: "ipad-01", timestamp: Fixtures.time(0))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"sequence":2,"device":"ipad-0"#.utf8))
        try handle.close()

        let reopened = try Journal(fileURL: url)

        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.skippedLineCount, 1)
    }

    func testDrawnPageIsIntactAfterTheAppIsKilledAndReopened() throws {
        let directory = Fixtures.temporaryDirectory()
        let store = try NotesStore(directory: directory, device: "ipad-01")
        let notebook = Notebook(id: "nb_01TEST", title: "Notes", updated: Fixtures.time(0), device: "ipad-01")
        let header = PageHeader(id: "p_01TEST", notebook: notebook.id, updated: Fixtures.time(0), device: "ipad-01")
        try store.apply(.notebook(notebook))
        try store.apply(.page(header))
        try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_A", at: 1)))
        try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_B", at: 2, order: 1, tool: .marker)))
        try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_A", at: 1).tombstone(at: Fixtures.time(3), device: "ipad-01")))
        let before = try XCTUnwrap(store.pages[header.id])

        let reopened = try NotesStore(directory: directory, device: "ipad-01")

        XCTAssertEqual(reopened.pages[header.id], before)
        XCTAssertEqual(reopened.pages[header.id]?.liveElements.map(\.id), ["e_B"])
        XCTAssertEqual(reopened.liveNotebooks.map(\.title), ["Notes"])
        XCTAssertEqual(try PageCodec.decodePage(try XCTUnwrap(reopened.encodedFile(at: RepositoryPath.page(notebook: notebook.id, page: header.id)))), before)
    }

    func testCompactionKeepsOneEntryPerChangedThingAndTheSameState() throws {
        let directory = Fixtures.temporaryDirectory()
        let store = try NotesStore(directory: directory, device: "ipad-01")
        let notebook = Notebook(id: "nb_01TEST", title: "Notes", updated: Fixtures.time(0), device: "ipad-01")
        var header = PageHeader(id: "p_01TEST", notebook: notebook.id, updated: Fixtures.time(0), device: "ipad-01")
        try store.apply(.notebook(notebook))
        try store.apply(.page(header))
        for second in 1...20 {
            try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_A", at: Double(second))))
        }
        try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_B", at: 21, order: 1)))
        try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_B", at: 21, order: 1).tombstone(at: Fixtures.time(22), device: "ipad-01")))
        try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_B", at: 23, order: 1)))
        try store.apply(.element(pageId: header.id, element: Fixtures.stroke("e_C", at: 24, order: 2)))
        header.title = "Renamed"
        header.updated = Fixtures.time(25)
        try store.apply(.page(header))
        let before = try XCTUnwrap(store.pages[header.id])
        let lastSequence = store.journal.lastSequence

        XCTAssertTrue(try store.compactJournal(above: 5))
        let reopened = try NotesStore(directory: directory, device: "ipad-01")

        XCTAssertLessThan(store.journal.entries.count, 8)
        XCTAssertEqual(reopened.pages[header.id], before)
        XCTAssertEqual(reopened.pages[header.id]?.liveElements.map(\.id), ["e_A", "e_C"])
        XCTAssertEqual(reopened.journal.lastSequence, lastSequence)
        XCTAssertEqual(Set(reopened.journal.entries.map(\.sequence)).count, reopened.journal.entries.count)
        let next = try reopened.journal.append(.element(pageId: header.id, element: Fixtures.stroke("e_D", at: 30)), device: "ipad-01", timestamp: Fixtures.time(30))
        XCTAssertEqual(next.sequence, (lastSequence ?? 0) + 1)
    }

    func testCompactionLeavesASmallJournalAlone() throws {
        let directory = Fixtures.temporaryDirectory()
        let store = try NotesStore(directory: directory, device: "ipad-01")
        let notebook = Notebook(id: "nb_01TEST", title: "Notes", updated: Fixtures.time(0), device: "ipad-01")
        try store.apply(.notebook(notebook))
        try store.apply(.notebook(notebook))

        XCTAssertFalse(try store.compactJournal(above: 5))
        XCTAssertEqual(store.journal.entries.count, 2)
    }

    func testFlushIsDueAfterFiveIdleSeconds() {
        var policy = FlushPolicy()
        policy.recordChange(page: "p_A", at: Fixtures.time(0))

        XCTAssertFalse(policy.isDue(at: Fixtures.time(4.9)))
        XCTAssertTrue(policy.isDue(at: Fixtures.time(5)))
    }

    func testInputResetsTheIdleTimerButNotTheMaximumAge() {
        var policy = FlushPolicy()
        policy.recordChange(page: "p_A", at: Fixtures.time(0))
        for second in stride(from: 3.0, through: 57.0, by: 3.0) {
            policy.recordInput(page: "p_A", at: Fixtures.time(second))
            XCTAssertFalse(policy.isDue(at: Fixtures.time(second + 1)))
        }

        policy.recordInput(page: "p_A", at: Fixtures.time(59))

        XCTAssertFalse(policy.isDue(at: Fixtures.time(59.5)))
        XCTAssertTrue(policy.isDue(at: Fixtures.time(60)))
    }

    func testCleanPolicyIsNeverDue() {
        var policy = FlushPolicy()
        policy.recordInput(page: "p_A", at: Fixtures.time(0))
        XCTAssertFalse(policy.isDue(at: Fixtures.time(100)))

        policy.recordChange(page: "p_A", at: Fixtures.time(0))
        policy.markFlushed()
        XCTAssertFalse(policy.isDue(at: Fixtures.time(100)))
    }

    func testAddingCellsKeepsElementsInPlace() {
        var page = Fixtures.page(elements: [Fixtures.stroke("e_A")])
        let original = page.elements
        var extents: [Extent] = [page.extent]
        page.extent = page.extent.addingColumn()
        extents.append(page.extent)
        page.extent = page.extent.addingRow()
        extents.append(page.extent)
        page.extent = page.extent.addingColumn()
        extents.append(page.extent)

        XCTAssertEqual(extents, [Extent(columns: 1, rows: 1), Extent(columns: 2, rows: 1), Extent(columns: 2, rows: 2), Extent(columns: 3, rows: 2)])
        XCTAssertEqual(page.elements, original)
        XCTAssertEqual(PaperGeometry.width(of: page.extent), 630)
    }

    func testEraserHitsStrokesWithinReach() {
        let stroke = Fixtures.stroke("e_A")

        XCTAssertTrue(StrokeGeometry.isHit(stroke, by: Point(x: 11, y: 12), radius: 1.5))
        XCTAssertFalse(StrokeGeometry.isHit(stroke, by: Point(x: 30, y: 30), radius: 1.5))
        XCTAssertFalse(StrokeGeometry.isHit(stroke.tombstone(at: Fixtures.time(1), device: "ipad-01"), by: Point(x: 11, y: 10.5), radius: 1.5))
    }
}
