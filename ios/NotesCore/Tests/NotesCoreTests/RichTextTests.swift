import XCTest
@testable import NotesCore

final class RichTextTests: XCTestCase {
    private func roundTrip(_ markdown: String) -> String {
        RichText.markdown(RichText.lines(markdown))
    }

    func testCanonicalMarkdownSurvivesTheEditorModel() {
        let samples = [
            "plain words",
            "**bold** and *italic* and ***both***",
            "~~gone~~ and `code` here",
            "<u>under</u> and <u class=\"dashed\">dashed</u>",
            "# Title",
            "## Section **strong**",
            "- item with *emphasis*",
            "  - [x] done task",
            "1. one\n2. two",
            "> quoted *line*",
            "[a link](https://example.com/path) after",
            "```\nlet value = *not emphasis*\n```",
            "---",
            "",
            "first\n\nthird",
        ]
        for sample in samples {
            XCTAssertEqual(roundTrip(sample), sample, sample)
        }
    }

    func testVisibleTextHidesInlineMarkersAndKeepsLinePrefixes() {
        let lines = RichText.lines("## **Bold** title\n- <u>item</u>")

        XCTAssertEqual(lines[0].map(\.text).joined(), "## Bold title")
        XCTAssertEqual(lines[1].map(\.text).joined(), "- item")
        XCTAssertEqual(lines[1].last?.style, MarkdownStyle(isUnderlined: true))
    }

    func testAdjacentStylesSerialiseWithoutSwallowingEachOther() {
        let cases: [[MarkdownRun]] = [
            [MarkdownRun(text: "a", style: MarkdownStyle(isItalic: true)), MarkdownRun(text: "b", style: MarkdownStyle(isBold: true))],
            [MarkdownRun(text: "a", style: MarkdownStyle(isBold: true)), MarkdownRun(text: "b", style: MarkdownStyle(isItalic: true))],
            [MarkdownRun(text: "a", style: MarkdownStyle(isBold: true)), MarkdownRun(text: "b", style: MarkdownStyle(isBold: true, isItalic: true)), MarkdownRun(text: "c", style: MarkdownStyle(isItalic: true))],
            [MarkdownRun(text: "x", style: MarkdownStyle(isUnderlined: true)), MarkdownRun(text: "y", style: MarkdownStyle(isDashedUnderlined: true))],
            [MarkdownRun(text: "code", style: MarkdownStyle(isBold: true, isCode: true)), MarkdownRun(text: " tail", style: MarkdownStyle())],
            [MarkdownRun(text: "go", style: MarkdownStyle(isLink: true, linkTarget: "https://a.b")), MarkdownRun(text: "!", style: MarkdownStyle(isBold: true, isLink: true, linkTarget: "https://a.b")), MarkdownRun(text: " ", style: MarkdownStyle()), MarkdownRun(text: "out", style: MarkdownStyle(isBold: true))],
        ]
        for runs in cases {
            XCTAssertEqual(Markdown.runs(RichText.inline(runs)), runs, RichText.inline(runs))
        }
    }

    func testLiteralMarkupCharactersStayLiteral() {
        let literal = [MarkdownRun(text: "2 * 3 and *stars* and `ticks` and <u>tags</u> and a\\", style: MarkdownStyle())]
        let markdown = RichText.inline(literal)

        XCTAssertEqual(Markdown.runs(markdown), literal)
    }

    func testOnlyNeededEscapesAreWritten() {
        XCTAssertEqual(RichText.inline([MarkdownRun(text: "2 * 3 = 6", style: MarkdownStyle())]), "2 * 3 = 6")
        XCTAssertEqual(RichText.inline([MarkdownRun(text: "snake_case_name", style: MarkdownStyle())]), "snake_case_name")
    }

    func testEmphasisMovesEdgeSpacesOutside() {
        let runs = [MarkdownRun(text: "bold ", style: MarkdownStyle(isBold: true)), MarkdownRun(text: "plain", style: MarkdownStyle())]

        XCTAssertEqual(RichText.inline(runs), "**bold** plain")
    }

    func testEmphasisSplitByALinkTrimsEachPart() {
        let runs = [MarkdownRun(text: "go", style: MarkdownStyle(isBold: true, isLink: true, linkTarget: "https://a.b")), MarkdownRun(text: " out", style: MarkdownStyle(isBold: true))]
        let markdown = RichText.inline(runs)

        XCTAssertEqual(markdown, "[**go**](https://a.b) **out**")
        XCTAssertEqual(Markdown.runs(markdown), RichText.normalized(runs))
    }

    func testUnderlinedSpacesKeepTheirUnderline() {
        let runs = [MarkdownRun(text: "a b ", style: MarkdownStyle(isUnderlined: true)), MarkdownRun(text: "c", style: MarkdownStyle())]

        XCTAssertEqual(Markdown.runs(RichText.inline(runs)), runs)
    }

    func testEditedLinesComeBackAsMarkdown() {
        let lines: [[MarkdownRun]] = [
            [MarkdownRun(text: "# ", style: MarkdownStyle()), MarkdownRun(text: "Plan", style: MarkdownStyle(isItalic: true))],
            [MarkdownRun(text: "- ", style: MarkdownStyle()), MarkdownRun(text: "buy", style: MarkdownStyle(isStruck: true)), MarkdownRun(text: " milk", style: MarkdownStyle())],
            [MarkdownRun(text: "1. ", style: MarkdownStyle()), MarkdownRun(text: "call", style: MarkdownStyle(isDashedUnderlined: true))],
        ]

        XCTAssertEqual(RichText.markdown(lines), "# *Plan*\n- ~~buy~~ milk\n1. <u class=\"dashed\">call</u>")
    }

    func testShapesFollowFencesAndPrefixes() {
        let shapes = RichText.shapes(["# A", "```", "# not a heading", "```", "- [ ] task", "12) twelve", ">quote"])

        XCTAssertEqual(shapes.map(\.kind), [.heading, .code, .code, .code, .task, .numbered, .quote])
        XCTAssertEqual(shapes.map(\.prefixLength), [2, 3, 15, 3, 6, 4, 1])
        XCTAssertEqual(shapes[0].scale, Markdown.headingScales[0])
    }

    func testCodeSpansKeepTheirLanguageBesideProse() {
        let markdown = "Given text example `let x = 1`{.javascript} Is the given code"
        let runs = Markdown.runs(markdown)

        XCTAssertEqual(runs.map(\.text), ["Given text example ", "let x = 1", " Is the given code"])
        XCTAssertEqual(runs[1].style, MarkdownStyle(isCode: true, codeLanguage: .javascript))
        XCTAssertEqual(roundTrip(markdown), markdown)
        XCTAssertEqual(Markdown.runs("`x`{.py}").first?.style.codeLanguage, .python)
        XCTAssertEqual(Markdown.runs("`x`{.rust}").map(\.text), ["x", "{.rust}"])
    }

    func testAdjacentCodeSpansOfDifferentLanguagesStayApart() {
        let runs = [
            MarkdownRun(text: "a", style: MarkdownStyle(isCode: true, codeLanguage: .csharp)),
            MarkdownRun(text: "b", style: MarkdownStyle(isCode: true, codeLanguage: .java)),
            MarkdownRun(text: "{.python} literal", style: MarkdownStyle()),
        ]

        XCTAssertEqual(Markdown.runs(RichText.inline(runs)), runs)
    }

    func testCodeBlocksCarryTheirFenceLanguage() {
        let markdown = "intro\n```python\ndef f():\n    return 1\n```\nafter"
        let blocks = Markdown.blocks(markdown)
        let shapes = RichText.shapes(markdown.components(separatedBy: "\n"))

        XCTAssertEqual(blocks.filter { $0.kind == .code }.map(\.language), [.python, .python])
        XCTAssertEqual(shapes.map(\.language), [nil, .python, .python, .python, .python, nil])
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testRemovingCodeLeavesPlainText() {
        let runs = RichText.lines("say `x * y`{.java} now")[0].map { MarkdownRun(text: $0.text, style: MarkdownStyle()) }

        XCTAssertEqual(Markdown.runs(RichText.inline(runs)), [MarkdownRun(text: "say x * y now", style: MarkdownStyle())])
    }

    func testCodeEditsMergeAndSurviveTheCodec() throws {
        let older = Fixtures.text("e_C", "run `go()`{.javascript}", at: 1, device: "pc-01")
        let newer = Fixtures.text("e_C", "run `go()`{.python}\n```csharp\nvar a = 1;\n```", at: 2, device: "ipad-01")
        let merged = Merge.page(Fixtures.page(elements: [older]), Fixtures.page(elements: [newer]))

        let decoded = try PageCodec.decodePage(PageCodec.encodePage(merged))
        let content = decoded.element(withId: "e_C")?.content ?? ""

        XCTAssertEqual(content, newer.content)
        XCTAssertEqual(Markdown.runs("run `go()`{.python}").last?.style.codeLanguage, .python)
        XCTAssertEqual(Markdown.blocks(content).last?.language, .csharp)
    }

    func testStyledContentSurvivesTheCodec() throws {
        let content = "# *Plan*\n- ~~buy~~ <u>milk</u>\n<u class=\"dashed\">later</u> `now`"
        let page = Fixtures.page(elements: [Fixtures.text("e_T", content, at: 1, device: "ipad-01")])

        let decoded = try PageCodec.decodePage(PageCodec.encodePage(page))

        XCTAssertEqual(decoded.element(withId: "e_T")?.content, content)
        XCTAssertEqual(roundTrip(decoded.element(withId: "e_T")?.content ?? ""), content)
    }

    func testStyledEditsMergeByLatestEdit() {
        let plain = Fixtures.text("e_T", "plan for today", at: 1, device: "pc-01")
        let styled = Fixtures.text("e_T", "plan for **today** <u class=\"dashed\">maybe</u>", at: 2, device: "ipad-01")
        let merged = Merge.page(Fixtures.page(elements: [plain]), Fixtures.page(elements: [styled]))
        let reversed = Merge.page(Fixtures.page(elements: [styled]), Fixtures.page(elements: [plain]))

        XCTAssertEqual(merged.element(withId: "e_T")?.content, styled.content)
        XCTAssertEqual(reversed.element(withId: "e_T")?.content, styled.content)
        let runs = Markdown.runs(merged.element(withId: "e_T")?.content ?? "")
        XCTAssertEqual(runs.map(\.style), [MarkdownStyle(), MarkdownStyle(isBold: true), MarkdownStyle(), MarkdownStyle(isDashedUnderlined: true)])
    }
}
