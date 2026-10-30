import XCTest
@testable import NotesCore

final class SyntaxHighlighterTests: XCTestCase {
    private func pieces(_ text: String, _ language: CodeLanguage) -> [String] {
        SyntaxHighlighter.tokens(text, language: language).map { "\($0.kind.rawValue):\(text[$0.range])" }
    }

    func testJavaScript() {
        XCTAssertEqual(
            pieces("const total = `sum ${a}` + 'x' + 42 // done", .javascript),
            ["keyword:const", "string:`sum ${a}`", "string:'x'", "number:42", "comment:// done"]
        )
    }

    func testCSharp() {
        XCTAssertEqual(
            pieces("public int Count = 0x1F; /* note */ var s = \"a\\\"b\";", .csharp),
            ["keyword:public", "keyword:int", "number:0x1F", "comment:/* note */", "keyword:var", "string:\"a\\\"b\""]
        )
    }

    func testJava() {
        XCTAssertEqual(
            pieces("for (int i = 0; i < 10; i++) { return null; }", .java),
            ["keyword:for", "keyword:int", "number:0", "number:10", "keyword:return", "keyword:null"]
        )
    }

    func testPython() {
        XCTAssertEqual(
            pieces("def f(x2):\n    return \"\"\"multi\nline\"\"\" # end\n    pass", .python),
            ["keyword:def", "keyword:return", "string:\"\"\"multi\nline\"\"\"", "comment:# end", "keyword:pass"]
        )
    }

    func testCommentsAndStringsSpanLinesOnlyWhereTheLanguageAllows() {
        XCTAssertEqual(pieces("/* a\nb */ x", .java), ["comment:/* a\nb */"])
        XCTAssertEqual(pieces("'open\nclose'", .javascript), ["string:'open", "string:'"])
    }

    func testIdentifiersWithDigitsAreNotNumbers() {
        XCTAssertEqual(pieces("value2 = item3", .python), [])
    }

    func testLanguageIdentifiersAcceptCommonAliases() {
        XCTAssertEqual(CodeLanguage(identifier: "js"), .javascript)
        XCTAssertEqual(CodeLanguage(identifier: "C#"), .csharp)
        XCTAssertEqual(CodeLanguage(identifier: "py"), .python)
        XCTAssertNil(CodeLanguage(identifier: "rust"))
    }
}
