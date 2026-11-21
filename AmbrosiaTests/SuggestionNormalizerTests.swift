import XCTest
@testable import Ambrosia

final class SuggestionNormalizerTests: XCTestCase {

    func testDiacriticStripping() {
        XCTAssertEqual(SuggestionNormalizer.fold("Padmé"), "padme")
        XCTAssertEqual(SuggestionNormalizer.fold("RÉSUMÉ"), "resume")
        XCTAssertEqual(SuggestionNormalizer.fold("Café au Lait"), "cafe au lait")
        XCTAssertEqual(SuggestionNormalizer.fold("Håkon"), "hakon")
    }

    func testTokenization() {
        let tokens = SuggestionNormalizer.tokens(of: "James \"Bucky\" Barnes/Steve Rogers")
        XCTAssertEqual(tokens, ["james", "bucky", "barnes", "steve", "rogers"])

        let hyphenTokens = SuggestionNormalizer.tokens(of: "Spider-Man: Into the Spider-Verse")
        XCTAssertEqual(hyphenTokens, ["spider", "man", "into", "the", "spider", "verse"])
    }

    func testStripTrailingQualifier() {
        let (base1, qual1) = SuggestionNormalizer.stripTrailingQualifier("Aziraphale/Crowley (Good Omens)")
        XCTAssertEqual(base1, "Aziraphale/Crowley")
        XCTAssertEqual(qual1, "Good Omens")

        let (base2, qual2) = SuggestionNormalizer.stripTrailingQualifier("Fluff")
        XCTAssertEqual(base2, "Fluff")
        XCTAssertNil(qual2)

        let (base3, qual3) = SuggestionNormalizer.stripTrailingQualifier("The Gaang (Avatar)")
        XCTAssertEqual(base3, "The Gaang")
        XCTAssertEqual(qual3, "Avatar")
    }

    func testIsRelationshipSeparator() {
        XCTAssertTrue(SuggestionNormalizer.isRelationshipSeparator("/"))
        XCTAssertTrue(SuggestionNormalizer.isRelationshipSeparator("&"))
        XCTAssertTrue(SuggestionNormalizer.isRelationshipSeparator("+"))
        XCTAssertTrue(SuggestionNormalizer.isRelationshipSeparator("|"))
        XCTAssertTrue(SuggestionNormalizer.isRelationshipSeparator(","))
        XCTAssertFalse(SuggestionNormalizer.isRelationshipSeparator("-"))
        XCTAssertFalse(SuggestionNormalizer.isRelationshipSeparator("x"))
    }
}
