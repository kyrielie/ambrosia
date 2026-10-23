import XCTest
@testable import Ambrosia

final class EPUBParserSanitizationTests: XCTestCase {

    func testSanitiseStripsPublisherStylesAndActiveContent() {
        let rawHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Chapter 1</title>
            <link rel="stylesheet" href="style.css" type="text/css">
            <style>body { background: red; }</style>
            <script>alert('evil');</script>
        </head>
        <body onload="doEvil()" style="margin: 20px;">
            <p style="color: blue;" onclick="steal()">Hello <a href="javascript:alert(1)">World</a></p>
        </body>
        </html>
        """

        let result = EPUBParser.sanitise(rawHTML, userCSS: "body { font-size: 16px; }", spineIndex: 3)

        // Verifications
        XCTAssertFalse(result.contains("style.css"), "Publisher stylesheet link must be stripped")
        XCTAssertFalse(result.contains("background: red"), "Publisher style block must be stripped")
        XCTAssertFalse(result.contains("alert('evil')"), "Script block must be stripped")
        XCTAssertFalse(result.contains("onload="), "onload attribute must be stripped")
        XCTAssertFalse(result.contains("onclick="), "onclick attribute must be stripped")
        XCTAssertFalse(result.contains("javascript:alert(1)"), "javascript: URL must be stripped")
        XCTAssertFalse(result.contains("style="), "Inline style attributes must be stripped")

        // User CSS and spine index must be injected
        XCTAssertTrue(result.contains("body { font-size: 16px; }"), "User CSS must be injected")
        XCTAssertTrue(result.contains("window.currentSpineIndex = 3;"), "Spine index tracker must be injected")
        XCTAssertTrue(result.contains("Hello"), "Body text must be preserved")
    }

    func testExtractBodyContentExtractsOnlyInnerBody() {
        let rawHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <link rel="stylesheet" href="main.css">
            <title>Doc</title>
        </head>
        <body>
            <div id="content"><p>First chapter</p></div>
        </body>
        </html>
        """

        let body = EPUBParser.extractBodyContent(from: rawHTML, isFirstSpineItem: false)
        XCTAssertFalse(body.contains("<html"), "Must not contain html tags")
        XCTAssertFalse(body.contains("<body"), "Must not contain body tags")
        XCTAssertFalse(body.contains("main.css"), "Must not contain publisher stylesheet")
        XCTAssertTrue(body.contains("<p>First chapter</p>"), "Must contain inner content")
    }

    func testExtractBodyContentStripsRedundantPrefaceOnFirstItemOnly() {
        let prefaceHTML = """
        <html><body>
        <h2 class="toc-heading">Preface</h2>
        <p>Author's note and work summary</p>
        </body></html>
        """

        let firstSpineResult = EPUBParser.extractBodyContent(from: prefaceHTML, isFirstSpineItem: true)
        XCTAssertFalse(firstSpineResult.contains("Preface"), "Redundant preface heading must be stripped on first spine item")
        XCTAssertTrue(firstSpineResult.contains("Author's note and work summary"))

        let laterSpineResult = EPUBParser.extractBodyContent(from: prefaceHTML, isFirstSpineItem: false)
        XCTAssertTrue(laterSpineResult.contains("Preface"), "Preface heading must NOT be stripped on subsequent spine items")
    }

    func testExtractBodyContentLeadingIndentWhitespaceRemoval() {
        let indentedHTML = """
        <html><body>
        <p>   This is an indented paragraph.</p>
        <p>This is a normal paragraph.</p>
        </body></html>
        """

        let cleaned = EPUBParser.extractBodyContent(from: indentedHTML, isFirstSpineItem: false, removeParagraphIndents: true)
        XCTAssertTrue(cleaned.contains("<p>This is an indented paragraph.</p>"), "Leading space run inside paragraph must be trimmed")

        let preserved = EPUBParser.extractBodyContent(from: indentedHTML, isFirstSpineItem: false, removeParagraphIndents: false)
        XCTAssertTrue(preserved.contains("<p>   This is an indented paragraph.</p>"), "Leading whitespace should be preserved if preference is false")
    }
}
