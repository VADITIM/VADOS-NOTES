import XCTest
@testable import NotesCore

final class CodecTests: XCTestCase {
    func testPageRoundTripsUnchanged() throws {
        let page = Fixtures.page(elements: [
            Fixtures.stroke("e_A", at: 1.234),
            Fixtures.stroke("e_B", at: 2, tool: .marker),
            Fixtures.text("e_T", "Typed \"quoted\" text / with slash\nand a new line", at: 3, device: "pc-01"),
            Fixtures.stroke("e_GONE", at: 4, deleted: true),
        ], extent: Extent(columns: 2, rows: 1), at: 4)

        let data = try PageCodec.encodePage(page)
        let decoded = try PageCodec.decodePage(data)

        XCTAssertEqual(decoded, Merge.page(page, Fixtures.page(at: -1)))
        XCTAssertEqual(try PageCodec.encodePage(decoded), data)
    }

    func testEncodingWritesOneElementPerLine() throws {
        let page = Fixtures.page(elements: [Fixtures.stroke("e_A"), Fixtures.stroke("e_B", order: 1)])
        let text = String(decoding: try PageCodec.encodePage(page), as: UTF8.self)
        let elementLines = text.split(separator: "\n").filter { $0.hasPrefix("    {") }

        XCTAssertEqual(elementLines.count, 2)
        XCTAssertTrue(text.contains("\"extent\": {\"cols\":1,\"rows\":1}"))
        XCTAssertTrue(text.contains("\"schema_version\": 1"))
    }

    func testEmptyPageEncodesAndDecodes() throws {
        let page = Fixtures.page()
        XCTAssertEqual(try PageCodec.decodePage(try PageCodec.encodePage(page)), page)
    }

    func testUnknownSchemaVersionIsRefused() {
        let data = Data(#"{"schema_version": 2, "id": "p_01X", "something": "new"}"#.utf8)

        XCTAssertThrowsError(try PageCodec.decodePage(data)) { error in
            XCTAssertEqual(error as? CodecError, .unsupportedSchemaVersion(2))
        }
    }

    func testMalformedJsonIsRefused() {
        XCTAssertThrowsError(try PageCodec.decodePage(Data("{ not json".utf8))) { error in
            guard case .malformed = error as? CodecError else { return XCTFail("Expected malformed, got \(error)") }
        }
    }

    func testStrokeOnTextLayerIsInvalid() throws {
        var stroke = Fixtures.stroke("e_A")
        stroke.layer = .text
        let data = try PageCodec.encodePage(Fixtures.page(elements: [stroke]))

        XCTAssertThrowsError(try PageCodec.decodePage(data)) { error in
            guard case .invalid = error as? CodecError else { return XCTFail("Expected invalid, got \(error)") }
        }
    }

    func testDuplicateElementIdsAreInvalid() throws {
        let data = try PageCodec.encodePage(Fixtures.page(elements: [Fixtures.stroke("e_A"), Fixtures.stroke("e_A", order: 1)]))

        XCTAssertThrowsError(try PageCodec.decodePage(data))
    }

    func testSpecExampleWithWholeSecondTimestampsDecodes() throws {
        let json = """
        {
          "schema_version": 1,
          "id": "p_01HSPEC",
          "notebook": "nb_01HSPEC",
          "updated": "2026-10-25T13:45:00Z",
          "device": "ipad-01",
          "deleted": false,
          "extent": { "cols": 2, "rows": 1 },
          "elements": [
            {
              "id": "e_01HSPEC",
              "type": "stroke",
              "layer": "ink",
              "order": 12,
              "tool": "pen",
              "color": "#1A1A1A",
              "width": 1.2,
              "points": [[120.5, 300.2], [121.0, 300.4], [121.8, 300.9]],
              "updated": "2026-10-25T13:44:10Z",
              "device": "ipad-01",
              "deleted": false
            }
          ]
        }
        """
        let page = try PageCodec.decodePage(Data(json.utf8))

        XCTAssertEqual(page.extent, Extent(columns: 2, rows: 1))
        XCTAssertEqual(page.elements.first?.points?.count, 3)
        XCTAssertEqual(page.elements.first?.points?.first, Point(x: 120.5, y: 300.2))
        XCTAssertEqual(page.updated, Timestamp.parse("2026-10-25T13:45:00Z"))
    }

    func testImportElementFromSpecDecodes() throws {
        let element = """
        {"id":"e_01HIMPORT","type":"import","layer":"import","order":0,"asset":"sha256:9f3a","source_page":0,
         "source_size_mm":[215.9,279.4],"placement":{"x":0,"y":0,"scale":1.0},"fit":"fit_cell",
         "updated":"2026-10-25T13:50:00Z","device":"ipad-01","deleted":false}
        """
        let decoded = try PageCodec.makeDecoder().decode(Element.self, from: Data(element.utf8))

        XCTAssertEqual(decoded.type, .importPage)
        XCTAssertEqual(decoded.fit, .fitCell)
        XCTAssertEqual(decoded.sourceSizeMillimetres, [215.9, 279.4])
    }

    func testNotebookRoundTrips() throws {
        let notebook = Notebook(id: "nb_01TEST", title: "Physik", updated: Fixtures.time(1), device: "ipad-01")
        XCTAssertEqual(try PageCodec.decodeNotebook(try PageCodec.encodeNotebook(notebook)), notebook)
    }

    func testIdentifiersSortByCreationTime() {
        let earlier = Identifier.make(prefix: "p", date: Fixtures.time(0))
        let later = Identifier.make(prefix: "p", date: Fixtures.time(1))

        XCTAssertLessThan(earlier, later)
        XCTAssertTrue(Identifier.hasPrefix("p", earlier))
        XCTAssertEqual(earlier.count, 28)
    }
}
