import XCTest
@testable import Ambrosia

final class TagVariantKeyTests: XCTestCase {

    func testReorderedTwoSideRelationship() {
        let key1 = TagVariantKey.key(for: "Thor/Loki")
        let key2 = TagVariantKey.key(for: "Loki/Thor")
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1, "/loki/thor")
    }

    func testReorderedThreeSideRelationship() {
        let key1 = TagVariantKey.key(for: "Tony Stark/Steve Rogers/Bucky Barnes")
        let key2 = TagVariantKey.key(for: "Bucky Barnes/Tony Stark/Steve Rogers")
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1, "/bucky barnes/steve rogers/tony stark")
    }

    func testParentheticalFandomSuffixStripped() {
        let key1 = TagVariantKey.key(for: "Thor/Loki (Marvel)")
        let key2 = TagVariantKey.key(for: "Thor/Loki")
        XCTAssertEqual(key1, key2)
    }

    func testRelationshipSuffixStripped() {
        let key1 = TagVariantKey.key(for: "Thor/Loki - Relationship")
        let key2 = TagVariantKey.key(for: "Thor/Loki")
        XCTAssertEqual(key1, key2)
    }

    func testPipeAliasStrippedWhenNoSlashInAlias() {
        let key1 = TagVariantKey.key(for: "Thor/Loki | Thorki")
        let key2 = TagVariantKey.key(for: "Thor/Loki")
        XCTAssertEqual(key1, key2)
    }

    func testPipeNotStrippedWhenSlashFollowsPipe() {
        // "A | B/C" should not strip "| B/C" because it contains a slash
        let key = TagVariantKey.key(for: "A | B/C")
        XCTAssertTrue(key.contains("a | b"))
    }

    func testLeadingImpliedStripped() {
        let key1 = TagVariantKey.key(for: "Implied Thor/Loki")
        let key2 = TagVariantKey.key(for: "Thor/Implied Loki")
        let key3 = TagVariantKey.key(for: "Thor/Loki")
        XCTAssertEqual(key1, key3)
        XCTAssertEqual(key2, key3)
    }

    func testSpacedXRelationship() {
        let key1 = TagVariantKey.key(for: "Thor x Loki")
        let key2 = TagVariantKey.key(for: "Thor/Loki")
        XCTAssertEqual(key1, key2)
    }

    func testAccentFolding() {
        let key1 = TagVariantKey.key(for: "Éowyn/Faramir")
        let key2 = TagVariantKey.key(for: "eowyn/faramir")
        XCTAssertEqual(key1, key2)
    }

    func testReaderVariants() {
        let expected = "/loki/reader"
        XCTAssertEqual(TagVariantKey.key(for: "Loki/y/n"), expected)
        XCTAssertEqual(TagVariantKey.key(for: "Loki/You"), expected)
        XCTAssertEqual(TagVariantKey.key(for: "Loki/your name"), expected)
        XCTAssertEqual(TagVariantKey.key(for: "Loki/female reader"), expected)
        XCTAssertEqual(TagVariantKey.key(for: "Loki/male reader"), expected)
        XCTAssertEqual(TagVariantKey.key(for: "Loki/fem!reader"), expected)
    }

    func testDelimiterIsolation() {
        let slashKey = TagVariantKey.key(for: "Thor/Loki")
        let ampersandKey = TagVariantKey.key(for: "Thor & Loki")
        XCTAssertNotEqual(slashKey, ampersandKey)
        XCTAssertTrue(slashKey.hasPrefix("/"))
        XCTAssertTrue(ampersandKey.hasPrefix("&"))
    }

    func testSingleSidedYouUnchanged() {
        // A standalone character named "You" must remain "you", NOT "reader"
        let key = TagVariantKey.key(for: "You")
        XCTAssertEqual(key, "you")
    }

    func testParentheticalMergeDocumentedBehavior() {
        // Parentheticals stripped: characters from different fandoms with same name merge under variants toggle
        let key1 = TagVariantKey.key(for: "John Watson (BBC Sherlock)")
        let key2 = TagVariantKey.key(for: "John Watson (Granada)")
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1, "john watson")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(TagVariantKey.key(for: ""), "")
        XCTAssertEqual(TagVariantKey.key(for: "   "), "")
    }
}
