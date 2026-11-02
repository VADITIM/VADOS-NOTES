import XCTest
@testable import NotesCore

final class CellSwapTests: XCTestCase {
    private func stroke(_ id: String, x: Double, y: Double) -> Element {
        Element.stroke(id: id, tool: .pen, color: "#1A1A1A", width: 0.5, points: [Point(x: x, y: y), Point(x: x + 2, y: y)], order: 0, updated: Fixtures.time(0), device: "ipad-01")
    }

    private func centre(_ element: Element) -> Point? {
        element.points?.first
    }

    func testSwappingTwoCellsExchangesTheirElements() {
        let first = stroke("e_A", x: 10, y: 10)
        let second = stroke("e_B", x: 220, y: 310)
        let untouched = stroke("e_C", x: 10, y: 310)

        let moved = CellSwap.moved([first, second, untouched], swapping: CellIndex(column: 0, row: 0), with: CellIndex(column: 1, row: 1), centre: centre)

        XCTAssertEqual(moved.map(\.id), ["e_A", "e_B"])
        XCTAssertEqual(moved[0].points?.first, Point(x: 220, y: 307))
        XCTAssertEqual(moved[1].points?.first, Point(x: 10, y: 13))
    }

    func testSwappingACellWithItselfMovesNothing() {
        let moved = CellSwap.moved([stroke("e_A", x: 10, y: 10)], swapping: CellIndex(column: 0, row: 0), with: CellIndex(column: 0, row: 0), centre: centre)

        XCTAssertTrue(moved.isEmpty)
    }
}
