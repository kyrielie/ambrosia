import XCTest
@testable import Ambrosia

/// `EPUBWordCounter` must agree with the counting it replaced: strip `<[^>]+>`,
/// then split on whitespace and newlines.
final class EPUBWordCounterTests: XCTestCase {

    private func reference(_ markup: String) -> Int {
        markup.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func count(_ markup: String) -> Int {
        EPUBWordCounter.wordCount(inMarkup: Data(markup.utf8))
    }

    func testMatchesReferenceOnRepresentativeMarkup() {
        let samples = [
            "",
            "   \n\t ",
            "one two  three\nfour",
            "<p>Hello <b>big</b> world</p>",
            "<p>a</p><p>b</p>",                       // tags remove with no separator: "ab"
            "line<br/>break and<br />more",
            "x < y and a > b",                          // "<" with a later ">" is a tag span
            "a < b",                                    // "<" never closed: literal text
            "empty <> tag",                             // "<>" is not matched by <[^>]+>
            "<a title=\"x>y\">link</a> text",           // first ">" ends the tag
            "caf\u{E9} na\u{EF}ve \u{4E16}\u{754C}",
            "nbsp\u{00A0}separated\u{3000}ideographic\u{2009}thin",
            "crlf\r\nline\r\nends",
            "<?xml version=\"1.0\"?><html><body><p>Words in body</p></body></html>"
        ]
        for sample in samples {
            XCTAssertEqual(count(sample), reference(sample), "Mismatch for: \(sample.debugDescription)")
        }
    }

    func testAbsoluteCounts() {
        // Tags are removed without inserting a space, so adjacent text joins (old behavior).
        XCTAssertEqual(count("<p>one two</p><p>three</p>"), 2)
        XCTAssertEqual(count("<p>one two</p>\n<p>three</p>"), 3)
        XCTAssertEqual(count(""), 0)
        XCTAssertEqual(count("<p></p>"), 0)
    }
}
