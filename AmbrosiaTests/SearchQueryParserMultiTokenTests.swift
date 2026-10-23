import XCTest
@testable import Ambrosia

final class SearchQueryParserMultiTokenTests: XCTestCase {

    func testParseMultiTokenExtractsMultipleScopedTokens() {
        let input = "author:Alice tag:Romance title:Mystery"
        let query = SearchQueryParser.parseMultiToken(input)

        XCTAssertEqual(query.authorTerms, ["Alice"])
        XCTAssertEqual(query.tagTerms, ["Romance"])
        XCTAssertEqual(query.titleTerms, ["Mystery"])
        XCTAssertTrue(query.plainTerms.isEmpty)
    }

    func testParseMultiTokenHandlesQuotedTerms() {
        let input = "author:\"Jane Doe\" tag:\"Slow Burn\" title:\"The Great Adventure\""
        let query = SearchQueryParser.parseMultiToken(input)

        XCTAssertEqual(query.authorTerms, ["Jane Doe"])
        XCTAssertEqual(query.tagTerms, ["Slow Burn"])
        XCTAssertEqual(query.titleTerms, ["The Great Adventure"])
        XCTAssertTrue(query.plainTerms.isEmpty)
    }

    func testParseMultiTokenLeavesUnprefixedTermsAsPlain() {
        let input = "author:Alice tag:Angst dragon egg"
        let query = SearchQueryParser.parseMultiToken(input)

        XCTAssertEqual(query.authorTerms, ["Alice"])
        XCTAssertEqual(query.tagTerms, ["Angst"])
        XCTAssertEqual(query.plainTerms, ["dragon", "egg"])
    }

    func testAsFilterRulesConvertsTokensToRules() async {
        let input = "author:\"Jane Doe\" tag:Fluff status:Complete"
        let query = SearchQueryParser.parseMultiToken(input)

        let rules = await query.asFilterRules()
        XCTAssertEqual(rules.count, 3)

        let authorRule = rules.first(where: { $0.field == .authorName })
        XCTAssertNotNil(authorRule)
        XCTAssertEqual(authorRule?.value, "Jane Doe")
        XCTAssertEqual(authorRule?.op, .equals)

        let tagRule = rules.first(where: { $0.field == .tag })
        XCTAssertNotNil(tagRule)
        XCTAssertEqual(tagRule?.value, "Fluff")
        XCTAssertEqual(tagRule?.op, .equals)

        let statusRule = rules.first(where: { $0.field == .status })
        XCTAssertNotNil(statusRule)
        XCTAssertEqual(statusRule?.value, "Complete")
        XCTAssertEqual(statusRule?.op, .equals)
    }

    func testAsFilterRulesClassifiesRatingTagsCorrectly() async {
        let input = "tag:Explicit"
        let query = SearchQueryParser.parseMultiToken(input)

        let rules = await query.asFilterRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].field, .rating)
        XCTAssertEqual(rules[0].op, .ratingAtMost)
        XCTAssertEqual(rules[0].value, "Explicit")
    }
}
