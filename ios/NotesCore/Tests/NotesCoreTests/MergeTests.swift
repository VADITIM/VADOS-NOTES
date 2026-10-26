import XCTest
@testable import NotesCore

final class MergeTests: XCTestCase {
    func testUnionKeepsElementsAddedOnBothDevices() {
        let ipad = Fixtures.page(elements: [Fixtures.stroke("e_A", device: "ipad-01")])
        let computer = Fixtures.page(elements: [Fixtures.stroke("e_B", device: "pc-01")])

        let merged = Merge.page(ipad, computer)

        XCTAssertEqual(Set(merged.elements.map(\.id)), ["e_A", "e_B"])
    }

    func testTombstoneWinsOverOlderCopy() {
        let live = Fixtures.stroke("e_A", at: 0)
        let tombstone = live.tombstone(at: Fixtures.time(5), device: "pc-01")

        XCTAssertTrue(Merge.element(live, tombstone).deleted)
        XCTAssertTrue(Merge.element(tombstone, live).deleted)
    }

    func testTombstoneWinsOverNewerCopyWithoutDeletion() {
        let tombstone = Fixtures.stroke("e_A", at: 1).tombstone(at: Fixtures.time(2), device: "pc-01")
        let newerEdit = Fixtures.stroke("e_A", at: 10, device: "ipad-01")

        XCTAssertTrue(Merge.element(newerEdit, tombstone).deleted)
        XCTAssertTrue(Merge.element(tombstone, newerEdit).deleted)
    }

    func testLatestEditWinsPerElement() {
        let older = Fixtures.text("e_T", "first draft", at: 1, device: "pc-01")
        let newer = Fixtures.text("e_T", "second draft", at: 2, device: "ipad-01")

        XCTAssertEqual(Merge.element(older, newer).content, "second draft")
        XCTAssertEqual(Merge.element(newer, older).content, "second draft")
    }

    func testEqualTimestampsBreakTiesByDeviceInEitherOrder() {
        let fromComputer = Fixtures.text("e_T", "computer", at: 3, device: "pc-01")
        let fromTablet = Fixtures.text("e_T", "tablet", at: 3, device: "ipad-01")

        XCTAssertEqual(Merge.element(fromComputer, fromTablet).content, "computer")
        XCTAssertEqual(Merge.element(fromTablet, fromComputer).content, "computer")
    }

    func testConcurrentEditsOnOnePageMergeElementByElement() {
        let erasable = Fixtures.stroke("e_S", at: 0)
        let ipad = Fixtures.page(elements: [
            Fixtures.text("e_T", "edited on ipad", at: 4, device: "ipad-01"),
            erasable,
            Fixtures.stroke("e_NEW_IPAD", at: 4, device: "ipad-01", order: 1),
        ])
        let computer = Fixtures.page(elements: [
            Fixtures.text("e_T", "edited on pc", at: 6, device: "pc-01"),
            erasable.tombstone(at: Fixtures.time(5), device: "pc-01"),
            Fixtures.stroke("e_NEW_PC", at: 5, device: "pc-01", order: 2),
        ])

        let merged = Merge.page(ipad, computer)

        XCTAssertEqual(merged.element(withId: "e_T")?.content, "edited on pc")
        XCTAssertEqual(merged.element(withId: "e_S")?.deleted, true)
        XCTAssertNotNil(merged.element(withId: "e_NEW_IPAD"))
        XCTAssertNotNil(merged.element(withId: "e_NEW_PC"))
        XCTAssertEqual(merged.liveElements.count, 3)
    }

    func testPageMergeIsCommutativeAndIdempotent() {
        let first = Fixtures.page(elements: [Fixtures.stroke("e_A", at: 1), Fixtures.text("e_T", "one", at: 2, device: "ipad-01")], at: 2)
        let second = Fixtures.page(elements: [Fixtures.stroke("e_B", at: 3, device: "pc-01"), Fixtures.text("e_T", "two", at: 4, device: "pc-01")], at: 4, device: "pc-01")

        XCTAssertEqual(Merge.page(first, second), Merge.page(second, first))
        XCTAssertEqual(Merge.page(Merge.page(first, second), second), Merge.page(first, second))
    }

    func testExtentGrowsToTheUnionOfBothSides() {
        let wide = Fixtures.page(extent: Extent(columns: 2, rows: 1), at: 1)
        let tall = Fixtures.page(extent: Extent(columns: 1, rows: 2), at: 2)

        XCTAssertEqual(Merge.page(wide, tall).extent, Extent(columns: 2, rows: 2))
    }

    func testDeletedPageStaysDeleted() {
        var deleted = Fixtures.page(at: 1)
        deleted.deleted = true
        let newer = Fixtures.page(at: 9)

        XCTAssertTrue(Merge.page(deleted, newer).deleted)
        XCTAssertTrue(Merge.page(newer, deleted).deleted)
    }

    func testNotebookTitleIsLatestWriteWins() {
        let older = Notebook(id: "nb_01TEST", title: "Maths", updated: Fixtures.time(1), device: "pc-01")
        let newer = Notebook(id: "nb_01TEST", title: "Maths II", updated: Fixtures.time(2), device: "ipad-01")

        XCTAssertEqual(Merge.notebook(older, newer).title, "Maths II")
        XCTAssertEqual(Merge.notebook(newer, older).title, "Maths II")
    }

    func testMergedElementsAreSortedByLayerThenOrder() {
        let page = Fixtures.page(elements: [
            Fixtures.text("e_TEXT", "words", at: 0, device: "pc-01"),
            Fixtures.stroke("e_INK", order: 0, tool: .pen),
            Fixtures.stroke("e_MARK", order: 5, tool: .marker),
        ])

        let merged = Merge.page(page, Fixtures.page())

        XCTAssertEqual(merged.elements.map(\.id), ["e_MARK", "e_INK", "e_TEXT"])
    }
}
