import XCTest
@testable import Ambrosia

/// Coverage for `RowDescriptionLimit.capped(_:limit:)` (`BookListRow.swift`),
/// the view-side description truncation used by list rows.
final class RowDescriptionLimitTests: XCTestCase {

    func testEmptyStringIsUnchanged() {
        XCTAssertEqual(RowDescriptionLimit.capped(""), "")
    }

    func testShortStringIsUnchanged() {
        XCTAssertEqual(RowDescriptionLimit.capped("A short summary."), "A short summary.")
    }

    func testExactlyAtLimitIsUnchanged() {
        let text = String(repeating: "a", count: RowDescriptionLimit.characters)
        XCTAssertEqual(RowDescriptionLimit.capped(text), text)
    }

    func testOneOverLimitIsTruncatedWithEllipsis() {
        let text = String(repeating: "a", count: RowDescriptionLimit.characters + 1)
        let result = RowDescriptionLimit.capped(text)
        XCTAssertTrue(result.hasSuffix("\u{2026}"))
        XCTAssertEqual(result, String(repeating: "a", count: RowDescriptionLimit.characters) + "\u{2026}")
    }

    func testTrailingWhitespaceIsTrimmedBeforeEllipsis() {
        let text = "abc   def"
        let result = RowDescriptionLimit.capped(text, limit: 6)
        XCTAssertEqual(result, "abc\u{2026}")
    }

    func testEmojiAreNotSplitMidCharacter() {
        let text = String(repeating: "\u{1F600}", count: 10)
        let result = RowDescriptionLimit.capped(text, limit: 4)
        XCTAssertEqual(result, String(repeating: "\u{1F600}", count: 4) + "\u{2026}")
    }

    func testCombiningMarksStayWithBaseCharacter() {
        // "e" + combining acute accent is one Character.
        let unit = "e\u{0301}"
        let text = String(repeating: unit, count: 10)
        let result = RowDescriptionLimit.capped(text, limit: 3)
        XCTAssertEqual(result, String(repeating: unit, count: 3) + "\u{2026}")
    }

    func testCustomLimitBelowLengthTruncates() {
        XCTAssertEqual(RowDescriptionLimit.capped("hello world", limit: 5), "hello\u{2026}")
    }
}
