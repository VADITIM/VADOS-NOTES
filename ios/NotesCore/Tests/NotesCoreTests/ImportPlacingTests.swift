import XCTest
@testable import NotesCore

final class ImportPlacingTests: XCTestCase {
    private func pdfPage(_ id: String, page: Int, column: Int = 0, row: Int, asset: String = "a_REPORT") -> Element {
        Element(
            id: id,
            type: .importPage,
            layer: .importLayer,
            order: page,
            asset: asset,
            sourcePage: page,
            sourceName: "report.pdf",
            sourceSizeMillimetres: [180, 250],
            placement: Placement(x: Double(column) * PaperGeometry.cellWidth + 15, y: Double(row) * PaperGeometry.cellHeight + 23.5, scale: 1),
            fit: .fitCell,
            inverted: false,
            updated: Fixtures.time(0),
            device: "ipad-01"
        )
    }

    private func applied(_ edit: ElementEdit, to elements: [Element]) -> [Element] {
        var result = elements
        for element in edit.after {
            if let index = result.firstIndex(where: { $0.id == element.id }) {
                result[index] = element
            } else {
                result.append(element)
            }
        }
        return result
    }

    private func reversal(of edit: ElementEdit, in elements: [Element], identifier: String) -> ElementEdit {
        edit.reversal(current: { id in elements.first { $0.id == id } }, now: Fixtures.time(5), device: "ipad-01", newIdentifier: { identifier })
    }

    private func place(_ page: Int, column: Int = 0, row: Int, in elements: [Element]) -> ElementEdit {
        ImportPlacing.placed(asset: "a_REPORT", sourcePage: page, at: CellIndex(column: column, row: row), in: elements, now: Fixtures.time(2), device: "ipad-01") {
            pdfPage("e_ADDED", page: page, column: column, row: row)
        }
    }

    private func live(_ elements: [Element]) -> [Element] {
        elements.filter { !$0.deleted }
    }

    func testPlacingAnUnusedPdfPageAddsItToTheTappedPage() {
        let ink = Fixtures.stroke("e_INK")
        let elements = [ink, pdfPage("e_FIRST", page: 0, row: 0)]

        let edit = place(1, row: 1, in: elements)

        XCTAssertTrue(edit.before.isEmpty)
        XCTAssertEqual(edit.after.map(\.id), ["e_ADDED"])
        XCTAssertEqual(ImportPlacing.cell(of: edit.after[0]), CellIndex(column: 0, row: 1))
        XCTAssertTrue(ImportPlacing.isPlaced(asset: "a_REPORT", sourcePage: 1, in: applied(edit, to: elements)))
    }

    func testPlacingAUsedPdfPageMovesItFromItsOldPage() {
        let ink = Fixtures.stroke("e_INK")
        let text = Fixtures.text("e_TEXT", "kept", at: 0, device: "ipad-01")
        let elements = [ink, text, pdfPage("e_FIRST", page: 0, row: 0)]

        let edit = place(0, column: 1, row: 1, in: elements)

        XCTAssertEqual(edit.after.map(\.id), ["e_FIRST"])
        XCTAssertEqual(edit.after[0].placement, Placement(x: PaperGeometry.cellWidth + 15, y: PaperGeometry.cellHeight + 23.5, scale: 1))
        XCTAssertEqual(edit.after[0].updated, Fixtures.time(2))
        XCTAssertEqual(edit.before, [elements[2]])
        let result = applied(edit, to: elements)
        XCTAssertEqual(result[0], ink)
        XCTAssertEqual(result[1], text)
    }

    func testPlacingOnAPageHoldingAnotherPdfPageRemovesThatPage() {
        let ink = Fixtures.stroke("e_INK", order: 1)
        let elements = [pdfPage("e_FIRST", page: 0, row: 0), pdfPage("e_SECOND", page: 1, row: 1), ink]

        let edit = place(0, row: 1, in: elements)

        XCTAssertEqual(edit.after.map(\.id), ["e_SECOND", "e_FIRST"])
        XCTAssertTrue(edit.after[0].deleted)
        let result = applied(edit, to: elements)
        XCTAssertFalse(ImportPlacing.isPlaced(asset: "a_REPORT", sourcePage: 1, in: result))
        XCTAssertEqual(live(result).filter { $0.type == .importPage }.compactMap(ImportPlacing.cell(of:)), [CellIndex(column: 0, row: 1)])
        XCTAssertEqual(result[2], ink)
    }

    func testPlacingAnUnusedPdfPageOverAnotherReplacesIt() {
        let elements = [pdfPage("e_FIRST", page: 0, row: 0)]

        let edit = place(1, row: 0, in: elements)

        XCTAssertEqual(edit.after.map(\.id), ["e_FIRST", "e_ADDED"])
        XCTAssertTrue(edit.after[0].deleted)
    }

    func testPlacingAPdfPageOnItsOwnPageChangesNothing() {
        let edit = place(0, row: 0, in: [pdfPage("e_FIRST", page: 0, row: 0)])

        XCTAssertEqual(edit, ElementEdit())
    }

    func testPagesOfAnotherPdfAreNotTheSamePage() {
        let elements = [pdfPage("e_OTHER", page: 0, row: 0, asset: "a_OTHER")]

        let edit = place(0, row: 0, in: elements)

        XCTAssertEqual(edit.after.map(\.id), ["e_OTHER", "e_ADDED"])
        XCTAssertTrue(ImportPlacing.isPlaced(asset: "a_OTHER", sourcePage: 0, in: elements))
    }

    func testOneUndoRevertsAMoveAndAReplacement() {
        let ink = Fixtures.stroke("e_INK", order: 1)
        let text = Fixtures.text("e_TEXT", "kept", at: 0, device: "ipad-01")
        let first = pdfPage("e_FIRST", page: 0, row: 0)
        let second = pdfPage("e_SECOND", page: 1, row: 1)
        let original = [first, second, ink, text]
        let edit = place(0, row: 1, in: original)
        let placed = applied(edit, to: original)

        let undo = reversal(of: edit, in: placed, identifier: "e_REVIVED")
        let undone = applied(undo, to: placed)

        let imports = live(undone).filter { $0.type == .importPage }
        XCTAssertEqual(imports.map(\.id), ["e_FIRST", "e_REVIVED"])
        XCTAssertEqual(imports[0].placement, first.placement)
        XCTAssertEqual(imports[1].sourcePage, 1)
        XCTAssertEqual(imports[1].placement, second.placement)
        XCTAssertEqual(undone.first { $0.id == "e_INK" }, ink)
        XCTAssertEqual(undone.first { $0.id == "e_TEXT" }, text)

        let redo = reversal(of: undo, in: undone, identifier: "e_UNUSED")
        let redone = live(applied(redo, to: undone)).filter { $0.type == .importPage }
        XCTAssertEqual(redone.map(\.id), ["e_FIRST"])
        XCTAssertEqual(ImportPlacing.cell(of: redone[0]), CellIndex(column: 0, row: 1))
    }

    func testUndoRemovesAnAddedPdfPage() {
        let elements = [pdfPage("e_FIRST", page: 0, row: 0)]
        let edit = place(1, row: 1, in: elements)
        let placed = applied(edit, to: elements)

        let undone = applied(reversal(of: edit, in: placed, identifier: "e_UNUSED"), to: placed)

        XCTAssertFalse(ImportPlacing.isPlaced(asset: "a_REPORT", sourcePage: 1, in: undone))
        XCTAssertTrue(ImportPlacing.isPlaced(asset: "a_REPORT", sourcePage: 0, in: undone))
    }

    func testSourceNameRoundTripsThroughTheCodec() throws {
        let element = pdfPage("e_FIRST", page: 0, row: 0)

        let decoded = try JSONDecoder().decode(Element.self, from: JSONEncoder().encode(element))

        XCTAssertEqual(decoded.sourceName, "report.pdf")
    }
}
