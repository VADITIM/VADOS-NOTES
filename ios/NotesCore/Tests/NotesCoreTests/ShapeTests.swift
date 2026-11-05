import XCTest
@testable import NotesCore

final class ShapeTests: XCTestCase {
    private func wobble(_ index: Int) -> Double {
        sin(Double(index) * 1.7) * 0.6
    }

    private func traced(_ corners: [Point], steps: Int = 24) -> [Point] {
        var points: [Point] = []
        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            for step in 0..<steps {
                let share = Double(step) / Double(steps)
                let count = points.count
                points.append(Point(x: start.x + (end.x - start.x) * share + wobble(count), y: start.y + (end.y - start.y) * share + wobble(count + 3)))
            }
        }
        points.append(Point(x: corners[0].x + 1.5, y: corners[0].y - 1))
        return points
    }

    private func ring(centre: Point, radiusX: Double, radiusY: Double, count: Int = 72) -> [Point] {
        (0...count).map { index in
            let angle = Double(index) / Double(count) * 2 * Double.pi
            return Point(x: centre.x + radiusX * cos(angle) + wobble(index) * 0.5, y: centre.y + radiusY * sin(angle) + wobble(index + 5) * 0.5)
        }
    }

    private func assertClose(_ first: Point, _ second: Point, accuracy: Double = 0.02, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(first.x, second.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(first.y, second.y, accuracy: accuracy, file: file, line: line)
    }

    func testRecognisesARectangleAndSquaresItsCorners() throws {
        let shape = try XCTUnwrap(ShapeRecognizer.recognize(traced([Point(x: 10, y: 10), Point(x: 70, y: 11), Point(x: 69, y: 50), Point(x: 11, y: 49)])))
        XCTAssertEqual(shape.outline, .polygon)
        XCTAssertEqual(shape.name, "rectangle")
        XCTAssertEqual(shape.anchors.count, 4)
        XCTAssertEqual(shape.radii, [0, 0, 0, 0])
        for index in shape.anchors.indices {
            XCTAssertEqual(ShapeRecognizer.angle(at: shape.anchors[index], shape.anchors[(index + 3) % 4], shape.anchors[(index + 1) % 4]), 90, accuracy: 0.5)
        }
        let xs = Set(shape.anchors.map { ($0.x * 10).rounded() })
        XCTAssertEqual(xs.count, 2, "an almost level rectangle snaps to the axes")
    }

    func testRecognisesATriangle() throws {
        let shape = try XCTUnwrap(ShapeRecognizer.recognize(traced([Point(x: 40, y: 10), Point(x: 75, y: 70), Point(x: 5, y: 70)])))
        XCTAssertEqual(shape.name, "triangle")
        XCTAssertEqual(shape.anchors.count, 3)
        assertClose(shape.anchors[0], Point(x: 40, y: 10), accuracy: 3)
    }

    func testRecognisesATrapezoidAndMakesItsBasesParallel() throws {
        let shape = try XCTUnwrap(ShapeRecognizer.recognize(traced([Point(x: 25, y: 10), Point(x: 65, y: 11), Point(x: 90, y: 60), Point(x: 5, y: 59)])))
        XCTAssertEqual(shape.name, "trapezoid")
        let top = atan2(shape.anchors[1].y - shape.anchors[0].y, shape.anchors[1].x - shape.anchors[0].x)
        let bottom = atan2(shape.anchors[2].y - shape.anchors[3].y, shape.anchors[2].x - shape.anchors[3].x)
        XCTAssertEqual(top, bottom, accuracy: 0.01)
    }

    func testRecognisesAPentagon() throws {
        let corners = (0..<5).map { index -> Point in
            let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / 5
            return Point(x: 50 + 40 * cos(angle), y: 50 + 40 * sin(angle))
        }
        let shape = try XCTUnwrap(ShapeRecognizer.recognize(traced(corners)))
        XCTAssertEqual(shape.name, "pentagon")
        XCTAssertEqual(shape.anchors.count, 5)
    }

    func testRecognisesACircleWithEightBezierAnchors() throws {
        let shape = try XCTUnwrap(ShapeRecognizer.recognize(ring(centre: Point(x: 50, y: 50), radiusX: 30, radiusY: 31)))
        XCTAssertEqual(shape.outline, .curve)
        XCTAssertEqual(shape.name, "circle")
        XCTAssertEqual(shape.anchors.count, 8)
        XCTAssertEqual(shape.handles?.count, 16)
        for point in shape.outlinePoints() {
            XCTAssertEqual(StrokeGeometry.distance(point, Point(x: 50, y: 50)), 30.5, accuracy: 1.2)
        }
    }

    func testAWideOvalStaysAnEllipse() throws {
        let shape = try XCTUnwrap(ShapeRecognizer.recognize(ring(centre: Point(x: 60, y: 40), radiusX: 50, radiusY: 20)))
        XCTAssertEqual(shape.name, "ellipse")
        XCTAssertEqual(shape.anchors.count, 8)
    }

    func testIgnoresOpenStrokesAndTinyMarks() {
        let line = (0..<40).map { Point(x: Double($0) * 2, y: sin(Double($0)) * 0.5) }
        XCTAssertNil(ShapeRecognizer.recognize(line))
        let hook = (0..<40).map { index -> Point in
            let angle = Double(index) / 40 * Double.pi * 1.2
            return Point(x: 30 * cos(angle), y: 30 * sin(angle))
        }
        XCTAssertNil(ShapeRecognizer.recognize(hook))
        XCTAssertNil(ShapeRecognizer.recognize(ring(centre: Point(x: 0, y: 0), radiusX: 2, radiusY: 2)))
    }

    func testOutlineIsClosed() {
        let shape = ShapeGeometry.polygon("triangle", [Point(x: 0, y: 0), Point(x: 40, y: 0), Point(x: 20, y: 30)])
        let outline = shape.outlinePoints()
        XCTAssertEqual(outline.first, outline.last)
        XCTAssertEqual(outline.count, 4)
    }

    func testCornerRadiusRoundsOnlyThatCornerAndIsClamped() {
        let square = ShapeGeometry.polygon("rectangle", [Point(x: 0, y: 0), Point(x: 40, y: 0), Point(x: 40, y: 40), Point(x: 0, y: 40)])
        XCTAssertEqual(square.maximumRadius(at: 0), 20, accuracy: 1e-9)
        let rounded = square.withRadius(8, at: 1)
        XCTAssertEqual(rounded.radii, [0, 8, 0, 0])
        let outline = rounded.outlinePoints()
        XCTAssertTrue(outline.contains(Point(x: 32, y: 0)))
        XCTAssertTrue(outline.contains(Point(x: 40, y: 8)))
        XCTAssertFalse(outline.contains(Point(x: 40, y: 0)))
        XCTAssertTrue(outline.contains(Point(x: 0, y: 0)))
        for point in outline where point.x > 32 && point.y < 8 {
            XCTAssertEqual(StrokeGeometry.distance(point, Point(x: 32, y: 8)), 8, accuracy: 0.02)
        }
        XCTAssertEqual(square.withRadius(100, at: 0).radii?[0], 20)
        XCTAssertEqual(square.withAllRadii(5).radii, [5, 5, 5, 5])
    }

    func testRadiusHandleRoundTripsAlongTheDiagonal() {
        let square = ShapeGeometry.polygon("rectangle", [Point(x: 0, y: 0), Point(x: 40, y: 0), Point(x: 40, y: 40), Point(x: 0, y: 40)]).withRadius(6, at: 0)
        let handle = try! XCTUnwrap(square.radiusHandle(at: 0, inset: 4))
        XCTAssertEqual(handle.x, handle.y, accuracy: 1e-9, "the handle sits on the corner's diagonal")
        XCTAssertEqual(square.radius(at: 0, forHandle: handle, inset: 4), 6, accuracy: 1e-6)
        XCTAssertEqual(square.radius(at: 0, forHandle: Point(x: -5, y: -5), inset: 4), 0)
    }

    func testMovingACurveAnchorCarriesItsHandles() {
        let circle = ShapeGeometry.ellipse("circle", center: Point(x: 0, y: 0), radiusX: 10, radiusY: 10)
        let moved = circle.movingAnchor(0, to: Point(x: 15, y: 2))
        XCTAssertEqual(moved.anchors[0], Point(x: 15, y: 2))
        assertClose(moved.handles![0], Point(x: circle.handles![0].x + 5, y: circle.handles![0].y + 2))
        assertClose(moved.handles![15], Point(x: circle.handles![15].x + 5, y: circle.handles![15].y + 2))
        XCTAssertEqual(moved.handles![2], circle.handles![2])
        XCTAssertEqual(circle.handleAnchor(0), 0)
        XCTAssertEqual(circle.handleAnchor(15), 0)
        let bent = circle.movingHandle(3, to: Point(x: 20, y: 20))
        XCTAssertEqual(bent.handles![3], Point(x: 20, y: 20))
        XCTAssertEqual(bent.anchors, circle.anchors)
    }

    func testShapesTravelWithLassoMovesAndScales() {
        var element = Fixtures.stroke("e_shape")
        element.shape = ShapeGeometry.polygon("rectangle", [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 10)]).withRadius(2, at: 0)
        let moved = Lasso.translated(element, by: Point(x: 5, y: 5))
        XCTAssertEqual(moved.shape?.anchors.first, Point(x: 5, y: 5))
        let scaled = Lasso.scaled(element, about: Point(x: 0, y: 0), by: 2)
        XCTAssertEqual(scaled.shape?.anchors[2], Point(x: 20, y: 20))
        XCTAssertEqual(scaled.shape?.radii?[0], 4)
    }

    func testShapeSurvivesTheCodecAndOldElementsStayUnchanged() throws {
        var element = Fixtures.stroke("e_shape")
        element.shape = ShapeGeometry.ellipse("circle", center: Point(x: 30, y: 30), radiusX: 10, radiusY: 10)
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(Element.self, from: data)
        XCTAssertEqual(decoded.shape, element.shape)
        let plain = try JSONEncoder().encode(Fixtures.stroke("e_plain"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"shape\""))
        XCTAssertNil(try JSONDecoder().decode(Element.self, from: plain).shape)
    }
}
