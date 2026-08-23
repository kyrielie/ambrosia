import XCTest
@testable import Ambrosia

/// Coverage for `HTMLStripper.strip(_:)` and `AnthologyDetector`
/// (`Ambrosia/Utilities/HTMLStripper.swift`).
final class HTMLStripperTests: XCTestCase {

    // MARK: - strip(_:)

    func testStripEmptyStringReturnsEmpty() {
        XCTAssertEqual(HTMLStripper.strip(""), "")
    }

    func testStripBlockTagsConvertToNewline() {
        XCTAssertEqual(HTMLStripper.strip("a<br>b"), "a\nb")
        XCTAssertEqual(HTMLStripper.strip("a<br/>b"), "a\nb")
        XCTAssertEqual(HTMLStripper.strip("a<br />b"), "a\nb")
        XCTAssertEqual(HTMLStripper.strip("<p>a</p>b"), "a\nb")
        XCTAssertEqual(HTMLStripper.strip("<div>a</div>b"), "a\nb")
        XCTAssertEqual(HTMLStripper.strip("<li>a</li>b"), "a\nb")
    }

    func testStripEntityDecoding() {
        XCTAssertEqual(HTMLStripper.strip("a &amp; b"), "a & b")
        XCTAssertEqual(HTMLStripper.strip("&lt;tag&gt;"), "<tag>") // decoded, not re-stripped as a tag
        XCTAssertEqual(HTMLStripper.strip("&quot;quoted&quot;"), "\"quoted\"")
        XCTAssertEqual(HTMLStripper.strip("it&#39;s"), "it's")
        XCTAssertEqual(HTMLStripper.strip("it&apos;s"), "it's")
        XCTAssertEqual(HTMLStripper.strip("a&nbsp;b"), "a b")
        // Zero-width space is stripped, not decoded to any visible character.
        XCTAssertEqual(HTMLStripper.strip("a&#8203;b"), "ab")
    }

    func testStripCollapsesThreeOrMoreNewlinesToTwo() {
        let input = "a\n\n\n\n\nb" // via literal newlines (already-decoded input)
        XCTAssertEqual(HTMLStripper.strip(input), "a\n\nb")
    }

    func testStripTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(HTMLStripper.strip("   hello world   "), "hello world")
        XCTAssertEqual(HTMLStripper.strip("\n\nhello\n\n"), "hello")
    }

    func testStripStripsRemainingTags() {
        XCTAssertEqual(HTMLStripper.strip("<span class=\"x\">hello</span>"), "hello")
    }

    /// The NSCache actually caches: calling strip twice with the same input
    /// returns equal output. This is the only test that would catch someone
    /// breaking the cache key by e.g. hashing instead of using the raw string.
    func testStripCachesRepeatedInput() {
        let input = "<p>Cached input</p>"
        let first = HTMLStripper.strip(input)
        let second = HTMLStripper.strip(input)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "Cached input")
    }

    // MARK: - AnthologyDetector.isAnthology(strippedComment:)

    func testIsAnthologyStrippedCommentExactPrefixMatch() {
        XCTAssertTrue(AnthologyDetector.isAnthology(strippedComment: "Anthology containing:\nWork One\nWork Two"))
    }

    func testIsAnthologyStrippedCommentCaseInsensitive() {
        XCTAssertTrue(AnthologyDetector.isAnthology(strippedComment: "anthology containing:\nWork One"))
        XCTAssertTrue(AnthologyDetector.isAnthology(strippedComment: "ANTHOLOGY CONTAINING:\nWork One"))
    }

    func testIsAnthologyStrippedCommentFalsePositiveGuard() {
        // Merely *containing* the word "anthology" elsewhere must not match --
        // this is an anchored prefix match, not a substring search.
        XCTAssertFalse(AnthologyDetector.isAnthology(strippedComment: "This is a story about an anthology of poems."))
    }

    func testIsAnthologyStrippedCommentEmptyStringReturnsFalse() {
        XCTAssertFalse(AnthologyDetector.isAnthology(strippedComment: ""))
    }

    // MARK: - AnthologyDetector.isAnthology(rawComment:)

    func testIsAnthologyRawCommentIsStripThenCheck() {
        let raw = "<p>Anthology containing:</p><p>Work One</p>"
        XCTAssertTrue(AnthologyDetector.isAnthology(rawComment: raw))

        let rawNonAnthology = "<p>A regular description mentioning anthology in passing.</p>"
        XCTAssertFalse(AnthologyDetector.isAnthology(rawComment: rawNonAnthology))
    }
}
