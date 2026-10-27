import XCTest
@testable import NotesCore

final class LassoTests: XCTestCase {
    private let square = [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)]

    func testContainsPointsInsideTheLoopOnly() {
        XCTAssertTrue(Lasso.contains(square, Point(x: 50, y: 50)))
        XCTAssertFalse(Lasso.contains(square, Point(x: 150, y: 50)))
        XCTAssertFalse(Lasso.contains([Point(x: 0, y: 0), Point(x: 10, y: 10)], Point(x: 5, y: 5)))
    }

    func testTouchesStrokesWithAnyPointInsideOrCrossingTheLoop() {
        XCTAssertTrue(Lasso.touches(square, line: [Point(x: 90, y: 90), Point(x: 120, y: 90), Point(x: 130, y: 90)]))
        XCTAssertTrue(Lasso.touches(square, line: [Point(x: -20, y: 50), Point(x: 120, y: 50)]))
        XCTAssertFalse(Lasso.touches(square, line: [Point(x: 120, y: 10), Point(x: 130, y: 90)]))
    }

    func testTouchesAreasThatOverlapTheLoop() {
        XCTAssertTrue(Lasso.touches(square, area: [Point(x: 90, y: 90), Point(x: 200, y: 90), Point(x: 200, y: 200), Point(x: 90, y: 200)]))
        XCTAssertTrue(Lasso.touches(square, area: [Point(x: -50, y: -50), Point(x: 150, y: -50), Point(x: 150, y: 150), Point(x: -50, y: 150)]))
        XCTAssertTrue(Lasso.touches(square, area: [Point(x: 40, y: -20), Point(x: 60, y: -20), Point(x: 60, y: 120), Point(x: 40, y: 120)]))
        XCTAssertFalse(Lasso.touches(square, area: [Point(x: 120, y: 0), Point(x: 140, y: 0), Point(x: 140, y: 20), Point(x: 120, y: 20)]))
    }

    func testTranslatedMovesPointsAndBoxes() {
        let stroke = Lasso.translated(Fixtures.stroke("e_1"), by: Point(x: 5, y: -2))
        XCTAssertEqual(stroke.points?.first, Point(x: 15, y: 8))
        let text = Lasso.translated(Fixtures.text("e_2", "a", at: 0, device: "ipad-01"), by: Point(x: 5, y: -2))
        XCTAssertEqual(text.box, TextBox(x: 25, y: 28, width: 80))
    }

    func testCreationDateComesBackFromTheIdentifier() {
        let date = Date(timeIntervalSince1970: 1_793_000_000.123)
        let identifier = Identifier.make(prefix: Identifier.pagePrefix, date: date)
        XCTAssertEqual(Identifier.creationDate(of: identifier)?.timeIntervalSince1970 ?? 0, 1_793_000_000.123, accuracy: 0.001)
        XCTAssertNil(Identifier.creationDate(of: "plain"))
    }
}
