import XCTest
@testable import NotesCore

final class CodeIndentationTests: XCTestCase {
    func testEnterKeepsTheLineIndent() {
        let edit = CodeIndentation.newline(before: "    let a = 1;", after: "", language: .javascript, unit: 4)
        XCTAssertEqual(edit, CodeEdit(replacement: "\n    "))
    }

    func testEnterAfterAnOpeningBraceIndentsOneLevel() {
        let edit = CodeIndentation.newline(before: "function f() {", after: "", language: .javascript, unit: 4)
        XCTAssertEqual(edit, CodeEdit(replacement: "\n    "))
    }

    func testEnterBetweenBracesSplitsThemAroundAnIndentedLine() {
        let edit = CodeIndentation.newline(before: "  if (x) {", after: "}", language: .csharp, unit: 2)
        XCTAssertEqual(edit, CodeEdit(replacement: "\n    \n  ", caret: 5))
    }

    func testBracesInStringsAndCommentsAreIgnored() {
        XCTAssertEqual(CodeIndentation.newline(before: "let s = \"{\" // (", after: "", language: .javascript, unit: 4), CodeEdit(replacement: "\n"))
        XCTAssertEqual(CodeIndentation.newline(before: "x = '{'  # [", after: "", language: .python, unit: 4), CodeEdit(replacement: "\n"))
    }

    func testClosedBracketsDoNotIndent() {
        XCTAssertEqual(CodeIndentation.newline(before: "    call(a, [b]);", after: "", language: .java, unit: 4), CodeEdit(replacement: "\n    "))
    }

    func testPythonIndentsAfterAColonAndDedentsAfterReturn() {
        XCTAssertEqual(CodeIndentation.newline(before: "def f(x):", after: "", language: .python, unit: 4), CodeEdit(replacement: "\n    "))
        XCTAssertEqual(CodeIndentation.newline(before: "        return x", after: "", language: .python, unit: 4), CodeEdit(replacement: "\n    "))
        XCTAssertEqual(CodeIndentation.newline(before: "    passed = 1", after: "", language: .python, unit: 4), CodeEdit(replacement: "\n    "))
    }

    func testEnterSwallowsSpacesAfterTheCaret() {
        XCTAssertEqual(CodeIndentation.newline(before: "    a();", after: "   b();", language: .javascript, unit: 4), CodeEdit(replacement: "\n    ", removedAfter: 3))
    }

    func testTypingACloserOnABlankLineDedents() {
        XCTAssertEqual(CodeIndentation.closing(before: "        ", character: "}", unit: 4), CodeEdit(replacement: "    }", removedBefore: 8))
        XCTAssertNil(CodeIndentation.closing(before: "    x", character: "}", unit: 4))
        XCTAssertNil(CodeIndentation.closing(before: "    ", character: "a", unit: 4))
    }

    func testBackspaceInTheIndentRemovesOneLevel() {
        XCTAssertEqual(CodeIndentation.backspace(before: "        ", unit: 4), CodeEdit(replacement: "", removedBefore: 4))
        XCTAssertEqual(CodeIndentation.backspace(before: "      ", unit: 4), CodeEdit(replacement: "", removedBefore: 2))
        XCTAssertNil(CodeIndentation.backspace(before: "    a", unit: 4))
    }

    func testTabRunsToTheNextStop() {
        XCTAssertEqual(CodeIndentation.tab(before: "ab", unit: 4), CodeEdit(replacement: "  "))
        XCTAssertEqual(CodeIndentation.tab(before: "", unit: 2), CodeEdit(replacement: "  "))
    }

    func testUnitIsReadFromTheBlock() {
        XCTAssertEqual(CodeIndentation.unit(["if (a) {", "  b();", "    c();", "}"]), 2)
        XCTAssertEqual(CodeIndentation.unit(["x = 1", ""]), 4)
    }

    func testOpenersCloseThemselves() {
        XCTAssertEqual(CodeIndentation.opening(after: "", character: "{"), CodeEdit(replacement: "{}", caret: 1))
        XCTAssertEqual(CodeIndentation.opening(after: ")", character: "("), CodeEdit(replacement: "()", caret: 1))
        XCTAssertNil(CodeIndentation.opening(after: "x", character: "["))
        XCTAssertNil(CodeIndentation.opening(after: "", character: "a"))
    }

    func testTypingTheCloserStepsOverIt() {
        XCTAssertEqual(CodeIndentation.overtype(after: "}", character: "}"), CodeEdit(replacement: "}", removedAfter: 1))
        XCTAssertNil(CodeIndentation.overtype(after: ")", character: "}"))
    }

    func testBackspaceBetweenAPairRemovesBoth() {
        XCTAssertEqual(CodeIndentation.pairBackspace(before: "f(", after: ")"), CodeEdit(replacement: "", removedBefore: 1, removedAfter: 1))
        XCTAssertNil(CodeIndentation.pairBackspace(before: "f(", after: "]"))
    }
}
