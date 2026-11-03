import XCTest
@testable import NotesCore

final class InkTests: XCTestCase {
    private let settings = InkSettings(sampleSpacing: 1, smoothing: 2.6, simplify: 0.12, axisSnapDegrees: 7)

    func testSmoothingKeepsEndpointsAndCalmsJitter() {
        let raw = (0...40).map { index in Point(x: Double(index), y: index % 2 == 0 ? 0 : 0.6) }
        let smooth = Ink.smoothStroke(raw, scale: 1, settings: settings)

        XCTAssertEqual(smooth.first, Point(x: 0, y: 0))
        XCTAssertEqual(smooth.last, StrokeGeometry.rounded(raw[40]))
        let middle = smooth.filter { $0.x > 8 && $0.x < 32 }
        XCTAssertTrue(middle.allSatisfy { abs($0.y - 0.3) < 0.15 })
        XCTAssertLessThan(smooth.count, raw.count)
    }

    func testAxisSnapStraightensNearlyLevelLines() {
        XCTAssertEqual(Ink.axisSnapped(start: Point(x: 0, y: 0), end: Point(x: 100, y: 8), degrees: 7), Point(x: 100, y: 0))
        XCTAssertEqual(Ink.axisSnapped(start: Point(x: 0, y: 0), end: Point(x: 6, y: 90), degrees: 7), Point(x: 0, y: 90))
        XCTAssertEqual(Ink.axisSnapped(start: Point(x: 0, y: 0), end: Point(x: 50, y: 50), degrees: 7), Point(x: 50, y: 50))
    }

    func testFittedLineFollowsTheDrawnAngle() throws {
        let raw = (0...60).map { index -> Point in
            let wobble: Double = index % 3 == 0 ? 0.8 : -0.4
            return Point(x: 10 + Double(index), y: 20 + Double(index) * 0.5 + wobble)
        }
        let line = try XCTUnwrap(Ink.fittedLine(raw, minimumLength: 25, deviationShare: 0.12, detourShare: 1.3))

        XCTAssertEqual(line.start.x, 10, accuracy: 0.6)
        XCTAssertEqual(line.end.x, 70, accuracy: 0.6)
        let rise = line.end.y - line.start.y
        let run = line.end.x - line.start.x
        XCTAssertEqual(rise / run, 0.5, accuracy: 0.02)
    }

    func testFittedLineKeepsTheDrawingDirection() {
        let raw = (0...40).map { index in Point(x: 100 - Double(index), y: 50) }
        let line = Ink.fittedLine(raw, minimumLength: 25, deviationShare: 0.12, detourShare: 1.3)

        XCTAssertEqual(line?.start.x ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(line?.end.x ?? 0, 60, accuracy: 0.01)
    }

    func testFittedLineRejectsShortCurvedAndScribbledStrokes() {
        let short = (0...10).map { Point(x: Double($0), y: 0) }
        let arc = (0...60).map { index -> Point in
            let angle = Double(index) * Double.pi / 60
            return Point(x: 40 * cos(angle), y: 40 * sin(angle))
        }
        let scribble = (0...80).map { index -> Point in
            let phase = index % 20
            let reach = Double(phase < 10 ? phase : 20 - phase)
            return Point(x: reach * 4, y: Double(index) * 0.05)
        }

        XCTAssertNil(Ink.fittedLine(short, minimumLength: 25, deviationShare: 0.12, detourShare: 1.3))
        XCTAssertNil(Ink.fittedLine(arc, minimumLength: 25, deviationShare: 0.12, detourShare: 1.3))
        XCTAssertNil(Ink.fittedLine(scribble, minimumLength: 25, deviationShare: 0.12, detourShare: 1.3))
    }

    func testCutLeavesAGapExactlyWhereSwept() {
        let points = [Point(x: 0, y: 0), Point(x: 100, y: 0)]
        let pieces = Ink.cutStroke(points, from: Point(x: 50, y: -10), to: Point(x: 50, y: 10), reach: 2)

        XCTAssertEqual(pieces?.count, 2)
        XCTAssertEqual(pieces?[0].last?.x ?? 0, 48, accuracy: 0.01)
        XCTAssertEqual(pieces?[1].first?.x ?? 0, 52, accuracy: 0.01)
        XCTAssertNil(Ink.cutStroke(points, from: Point(x: 50, y: 20), to: Point(x: 60, y: 20), reach: 2))
    }

    func testClipSplitsStrokesAtThePaperEdge() {
        let extent = Extent.single
        let points = [Point(x: -20, y: 50), Point(x: 30, y: 50), Point(x: 30, y: 400), Point(x: 60, y: 100), Point(x: 80, y: 100)]
        let pieces = Ink.clipToPaper(points, extent: extent)

        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].first, Point(x: 0, y: 50))
        XCTAssertEqual(pieces[0].last?.y ?? 0, 297, accuracy: 0.01)
        XCTAssertEqual(pieces[1].last, Point(x: 80, y: 100))
        XCTAssertEqual(Ink.clipToPaper([Point(x: 1, y: 1), Point(x: 2, y: 2)], extent: extent).count, 1)
    }

    func testSiblingsSortByOrderThenByIdentifier() {
        let now = Fixtures.time(0)
        let plain = Notebook(id: "nb_A", title: "A", updated: now, device: "pc")
        let moved = Notebook(id: "nb_B", title: "B", updated: now, device: "pc", order: 0)
        let last = Notebook(id: "nb_C", title: "C", updated: now, device: "pc", order: 5)

        XCTAssertEqual(Arrangement.sorted([last, plain, moved]).map(\.id), ["nb_A", "nb_B", "nb_C"])
        XCTAssertEqual(Arrangement.endOrder(after: [plain, moved, last]), 6)
        XCTAssertEqual(Arrangement.endOrder(after: [Notebook]()), 0)
    }

    func testMarkdownInlineStyles() {
        let runs = Markdown.runs("**bold *it* x** and `code` ~~gone~~ [link](http://a.b) snake_case")

        XCTAssertEqual(runs.first, MarkdownRun(text: "bold ", style: MarkdownStyle(isBold: true)))
        XCTAssertTrue(runs.contains(MarkdownRun(text: "it", style: MarkdownStyle(isBold: true, isItalic: true))))
        XCTAssertTrue(runs.contains(MarkdownRun(text: "code", style: MarkdownStyle(isCode: true))))
        XCTAssertTrue(runs.contains(MarkdownRun(text: "gone", style: MarkdownStyle(isStruck: true))))
        XCTAssertTrue(runs.contains(MarkdownRun(text: "link", style: MarkdownStyle(isLink: true, linkTarget: "http://a.b"))))
        XCTAssertEqual(runs.last?.text, " snake_case")
        XCTAssertEqual(Markdown.runs("a * b * c"), [MarkdownRun(text: "a * b * c", style: MarkdownStyle())])
    }

    func testMarkdownBlocks() {
        let blocks = Markdown.blocks("# Title\n- item\n  - nested\n- [x] done\n1. first\n> quote\n---\n```\ncode **raw**\n```\ntext")

        XCTAssertEqual(blocks.map(\.kind), [.heading, .bullet, .bullet, .task, .numbered, .quote, .rule, .code, .paragraph])
        XCTAssertEqual(blocks[2].indent, 2)
        XCTAssertTrue(blocks[3].isChecked)
        XCTAssertEqual(blocks[4].marker, "1.")
        XCTAssertEqual(blocks[7].runs.first?.text, "code **raw**")
    }
}
