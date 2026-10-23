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

    func testParseMultiTokenNegationPrefixes() async {
        let input = "tag:Fluff -tag:Angst -author:\"Bad Author\""
        let query = SearchQueryParser.parseMultiToken(input)

        XCTAssertEqual(query.tagTerms, ["Fluff"])
        XCTAssertEqual(query.excludedTagTerms, ["Angst"])
        XCTAssertEqual(query.excludedAuthorTerms, ["Bad Author"])

        let rules = await query.asFilterRules()
        XCTAssertEqual(rules.count, 3)

        let excludedTag = rules.first(where: { $0.field == .tag && $0.op == .notEquals })
        XCTAssertNotNil(excludedTag)
        XCTAssertEqual(excludedTag?.value, "Angst")

        let excludedAuthor = rules.first(where: { $0.field == .authorName && $0.op == .notEquals })
        XCTAssertNotNil(excludedAuthor)
        XCTAssertEqual(excludedAuthor?.value, "Bad Author")
    }

    func testParseMultiTokenWordCountRanges() async {
        let gtInput = "words:>50k tag:Romance"
        let gtQuery = SearchQueryParser.parseMultiToken(gtInput)
        XCTAssertEqual(gtQuery.wordCountGT, 50000)

        let gtRules = await gtQuery.asFilterRules()
        let gtRule = gtRules.first(where: { $0.field == .wordCountGT })
        XCTAssertNotNil(gtRule)
        XCTAssertEqual(gtRule?.value, "50000")

        let rangeInput = "words:10k-30k"
        let rangeQuery = SearchQueryParser.parseMultiToken(rangeInput)
        XCTAssertEqual(rangeQuery.wordCountGT, 10000)
        XCTAssertEqual(rangeQuery.wordCountLT, 30000)

        let rangeRules = await rangeQuery.asFilterRules()
        XCTAssertEqual(rangeRules.count, 2)
        XCTAssertTrue(rangeRules.contains(where: { $0.field == .wordCountGT && $0.value == "10000" }))
        XCTAssertTrue(rangeRules.contains(where: { $0.field == .wordCountLT && $0.value == "30000" }))
    }
}
