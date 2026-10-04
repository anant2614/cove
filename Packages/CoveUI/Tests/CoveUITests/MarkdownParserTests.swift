import XCTest
@testable import CoveUI

final class MarkdownParserTests: XCTestCase {
    func testHeadingsParagraphsAndRules() {
        let blocks = MarkdownParser.parse("# Title\n\nHello **world**\nsecond line\n\n---\n## Sub ##")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Hello **world**\nsecond line"),
            .thematicBreak,
            .heading(level: 2, text: "Sub"),
        ])
    }

    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(MarkdownParser.parse("#hashtag"), [.paragraph("#hashtag")])
    }

    func testFencedCodeClosedAndStreaming() {
        let closed = MarkdownParser.parse("Intro\n```swift\nlet x = 1\n```\nAfter")
        XCTAssertEqual(closed, [.paragraph("Intro"), .code(language: "swift", code: "let x = 1", isClosed: true), .paragraph("After")])

        let open = MarkdownParser.parse("```python\nprint('hi')\n")
        XCTAssertEqual(open, [.code(language: "python", code: "print('hi')\n", isClosed: false)])
    }

    func testMathBlocks() {
        XCTAssertEqual(MarkdownParser.parse("$$ E = mc^2 $$"), [.math("E = mc^2")])
        XCTAssertEqual(MarkdownParser.parse("$$\n\\int_0^1 x\\,dx\n$$"), [.math("\\int_0^1 x\\,dx")])
        XCTAssertEqual(MarkdownParser.parse("\\[\na+b\n\\]"), [.math("a+b")])
    }

    func testLists() {
        let blocks = MarkdownParser.parse("- one\n- two\n  - nested\n- [x] done\n\n1. first\n2) second")
        XCTAssertEqual(blocks, [
            .list(ordered: false, items: [
                MarkdownListItem(text: "one"),
                MarkdownListItem(text: "two"),
                MarkdownListItem(text: "nested", indent: 1),
                MarkdownListItem(text: "done", checked: true),
            ]),
            .list(ordered: true, items: [
                MarkdownListItem(text: "first", number: 1),
                MarkdownListItem(text: "second", number: 2),
            ]),
        ])
    }

    func testQuote() {
        XCTAssertEqual(MarkdownParser.parse("> quoted\n> # inner"), [.quote([.paragraph("quoted"), .heading(level: 1, text: "inner")])])
    }

    func testTable() {
        let blocks = MarkdownParser.parse("| Name | Score |\n|:-----|------:|\n| A | 1 |\n| B \\| C |")
        XCTAssertEqual(blocks, [.table(header: ["Name", "Score"], alignments: [.leading, .trailing], rows: [["A", "1"], ["B | C", ""]])])
    }

    func testPipeLineWithoutSeparatorIsParagraph() {
        XCTAssertEqual(MarkdownParser.parse("| not a table"), [.paragraph("| not a table")])
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    func testSwiftTokens() {
        let tokens = SyntaxHighlighter().tokenize("let name = \"Cove\" // hi\nprint(42)", language: "swift")
        XCTAssertTrue(tokens.contains(CodeToken(text: "let", kind: .keyword)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "\"Cove\"", kind: .string)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "// hi", kind: .comment)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "print", kind: .function)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "42", kind: .number)))
        // Round-trips the source exactly.
        XCTAssertEqual(tokens.map(\.text).joined(), "let name = \"Cove\" // hi\nprint(42)")
    }

    func testPythonTripleQuotesAndComments() {
        let code = "def f():\n    \"\"\"doc \"quoted\" \"\"\"\n    return None  # done"
        let tokens = SyntaxHighlighter().tokenize(code, language: "py")
        XCTAssertTrue(tokens.contains(CodeToken(text: "\"\"\"doc \"quoted\" \"\"\"", kind: .string)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "# done", kind: .comment)))
        XCTAssertEqual(tokens.map(\.text).joined(), code)
    }

    func testUnknownLanguageIsPlain() {
        XCTAssertEqual(SyntaxHighlighter().tokenize("x", language: "brainfuck"), [CodeToken(text: "x", kind: .plain)])
    }

    func testIdentifierDigitsAreNotNumbers() {
        let tokens = SyntaxHighlighter().tokenize("var x2 = 3", language: "js")
        XCTAssertFalse(tokens.contains(CodeToken(text: "2", kind: .number)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "3", kind: .number)))
    }
}

final class LaTeXRendererTests: XCTestCase {
    func testCommonMath() {
        XCTAssertEqual(LaTeXRenderer.render("E = mc^2"), "E = mc²")
        XCTAssertEqual(LaTeXRenderer.render("\\frac{a}{b}"), "(a)/(b)")
        XCTAssertEqual(LaTeXRenderer.render("\\alpha + \\beta \\leq \\gamma"), "α + β ≤ γ")
        XCTAssertEqual(LaTeXRenderer.render("x_{i+1}"), "xᵢ₊₁")
        XCTAssertEqual(LaTeXRenderer.render("\\sum_{i=1}^{n} i"), "∑ᵢ₌₁ⁿ i")
        XCTAssertEqual(LaTeXRenderer.render("\\sqrt{x^2 + y^2}"), "√(x² + y²)")
        XCTAssertEqual(LaTeXRenderer.render("\\int_0^\\infty e^{-x}\\,dx"), "∫₀^∞ e⁻ˣ dx")
    }

    func testNestedFractionsAndUnknownCommandsArePreserved() {
        XCTAssertEqual(LaTeXRenderer.render("\\frac{\\frac{1}{2}}{3}"), "((1)/(2))/(3)")
        XCTAssertEqual(LaTeXRenderer.render("\\foo{x}"), "\\foox")
        XCTAssertEqual(LaTeXRenderer.render("\\text{if } x > 0"), "if x > 0")
    }
}
