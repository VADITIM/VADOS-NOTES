import XCTest
@testable import NotesCore

final class CellRemovalTests: XCTestCase {
    private func stroke(_ id: String, x: Double, y: Double) -> Element {
        Element.stroke(id: id, tool: .pen, color: "#1A1A1A", width: 0.5, points: [Point(x: x, y: y), Point(x: x + 2, y: y)], order: 0, updated: Fixtures.time(0), device: "ipad-01")
    }

    private func centre(_ element: Element) -> Point? {
        element.points?.first
    }

    func testRemovingAColumnDropsItsElementsAndShiftsLaterColumnsBack() {
        let first = stroke("e_A", x: 10, y: 10)
        let second = stroke("e_B", x: 220, y: 10)
        let third = stroke("e_C", x: 430, y: 300)

        let outcome = CellRemoval.outcome(of: [first, second, third], removing: 1, along: .columns, centre: centre)

        XCTAssertEqual(outcome.removed.map(\.id), ["e_B"])
        XCTAssertEqual(outcome.moved.map(\.id), ["e_C"])
        XCTAssertEqual(outcome.moved.first?.points?.first, Point(x: 220, y: 300))
    }

    func testRemovingARowShiftsLaterRowsUp() {
        let top = stroke("e_A", x: 10, y: 10)
        let bottom = stroke("e_B", x: 10, y: 310)

        let outcome = CellRemoval.outcome(of: [top, bottom], removing: 0, along: .rows, centre: centre)

        XCTAssertEqual(outcome.removed.map(\.id), ["e_A"])
        XCTAssertEqual(outcome.moved.first?.points?.first, Point(x: 10, y: 13))
    }

    func testAddingPutsOneCellAtTheRightOrBottom() {
        XCTAssertEqual(Extent(columns: 2, rows: 1).adding(.columns), Extent(columns: 3, rows: 1))
        XCTAssertEqual(Extent(columns: 2, rows: 3).adding(.rows), Extent(columns: 2, rows: 4))
    }

    func testExtentShrinksButNeverBelowOneCell() {
        XCTAssertEqual(Extent(columns: 2, rows: 2).removing(.columns), Extent(columns: 1, rows: 2))
        XCTAssertEqual(Extent.single.removing(.rows), Extent.single)
    }

    func testCellContainingAPointIsClampedToTheExtent() {
        let extent = Extent(columns: 2, rows: 1)

        XCTAssertEqual(extent.cell(containing: Point(x: 215, y: 5), along: .columns), 1)
        XCTAssertEqual(extent.cell(containing: Point(x: 900, y: 5), along: .columns), 1)
        XCTAssertEqual(extent.cell(containing: Point(x: -5, y: 5), along: .columns), 0)
    }
}
