import XCTest
@testable import Ambrosia

final class MarkupEscapingTests: XCTestCase {

    func testXMLEscapeReplacesTheFourCoreCharacters() {
        XCTAssertEqual(
            xmlEscape("<a href=\"x\">Tom & Jerry</a>"),
            "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&lt;/a&gt;"
        )
    }

    func testXMLEscapeEscapesAmpersandFirstSoEntitiesAreNotDoubleEscaped() {
        XCTAssertEqual(xmlEscape("<"), "&lt;")
        XCTAssertEqual(xmlEscape("&lt;"), "&amp;lt;")
    }

    func testXMLEscapeLeavesApostropheAndPlainTextAlone() {
        XCTAssertEqual(xmlEscape("it's fine"), "it's fine")
        XCTAssertEqual(xmlEscape(""), "")
        XCTAssertEqual(xmlEscape("naïve café"), "naïve café")
    }

    func testApostropheVariantAlsoEscapesSingleQuote() {
        XCTAssertEqual(xmlEscapeIncludingApostrophe("it's <b>"), "it&apos;s &lt;b&gt;")
    }

    func testApostropheVariantMatchesCoreEscapeWhenThereIsNoApostrophe() {
        let input = "Fic & \"Co\" <tag>"
        XCTAssertEqual(xmlEscapeIncludingApostrophe(input), xmlEscape(input))
    }
}
