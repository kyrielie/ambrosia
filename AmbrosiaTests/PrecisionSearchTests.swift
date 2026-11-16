// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SQLite
@testable import Ambrosia

final class PrecisionSearchTests: XCTestCase {

    func testSQLiteRegexFunctionRegistersAndEvaluates() throws {
        let db = try Connection(.inMemory)
        SQLiteRegexRegistration.register(on: db)

        let result1 = try db.scalar("SELECT regexp('^hello', 'hello world')") as? Int64
        XCTAssertEqual(result1, 1)

        let result2 = try db.scalar("SELECT regexp('\\blove\\b', 'glovemaker')") as? Int64
        XCTAssertEqual(result2, 0)

        let result3 = try db.scalar("SELECT regexp('\\blove\\b', 'Love in the air')") as? Int64
        XCTAssertEqual(result3, 1)

        // Invalid regex should safely return 0 without throwing
        let resultInvalid = try db.scalar("SELECT regexp('[invalid', 'text')") as? Int64
        XCTAssertEqual(resultInvalid, 0)
    }

    func testSearchQueryParserParsesExactAndRegexModes() {
        let exactTag = SearchQueryParser.parse("tag:=Romance")
        XCTAssertEqual(exactTag.tagTerms, ["Romance"])
        XCTAssertEqual(exactTag.scopedTagTerms.first?.mode, .exact)
        XCTAssertEqual(exactTag.scopedTagTerms.first?.value, "Romance")

        let regexTitle = SearchQueryParser.parse("title:~\"\\blove\\b\"")
        XCTAssertEqual(regexTitle.titleTerms, ["\\blove\\b"])
        XCTAssertEqual(regexTitle.scopedTitleTerms.first?.mode, .regex)

        let exactAuthor = SearchQueryParser.parse("author:=\"Jane Doe\"")
        XCTAssertEqual(exactAuthor.authorTerms, ["Jane Doe"])
        XCTAssertEqual(exactAuthor.scopedAuthorTerms.first?.mode, .exact)

        let regexSeries = SearchQueryParser.parse("series:~\"^Book \\d+\"")
        XCTAssertEqual(regexSeries.seriesTerms, ["^Book \\d+"])
        XCTAssertEqual(regexSeries.scopedSeriesTerms.first?.mode, .regex)

        let semanticQuery = SearchQueryParser.parse("semantic:enemies to lovers space opera")
        XCTAssertEqual(semanticQuery.semanticPhrase, "enemies to lovers space opera")
    }

    func testMultiTokenParsesExactAndRegexPrefixes() {
        let input = "tag:=Angst title:~\"^The \" -author:=Voldemort words:>10k"
        let query = SearchQueryParser.parseMultiToken(input)

        XCTAssertEqual(query.tagTerms, ["Angst"])
        XCTAssertEqual(query.scopedTagTerms.first?.mode, .exact)
        XCTAssertEqual(query.titleTerms, ["^The "])
        XCTAssertEqual(query.scopedTitleTerms.first?.mode, .regex)
        XCTAssertEqual(query.excludedAuthorTerms, ["Voldemort"])
        XCTAssertEqual(query.wordCountGT, 10_000)
    }

    func testAsSingleFilterRuleTranslatesOperators() {
        let queryExact = SearchQueryParser.parse("tag:=Fluff")
        let ruleExact = queryExact.asSingleFilterRule()
        XCTAssertEqual(ruleExact?.field, .tag)
        XCTAssertEqual(ruleExact?.op, .equals)
        XCTAssertEqual(ruleExact?.value, "Fluff")

        let queryRegex = SearchQueryParser.parse("title:~\"^The \"")
        let ruleRegex = queryRegex.asSingleFilterRule()
        XCTAssertEqual(ruleRegex?.field, .title)
        XCTAssertEqual(ruleRegex?.op, .matchesRegex)
        XCTAssertEqual(ruleRegex?.value, "^The ")
    }

    func testOccurrenceSnippetWordBoundariesPreventsFalsePositives() {
        guard let query = FTSQuery.make("love") else {
            XCTFail("Failed to make FTSQuery")
            return
        }

        let text = "He wore a pair of lovely gloves while inlove, but true love won the day."
        let result = FTSOccurrenceExtractor.extract(
            text: text,
            textRowID: 1,
            bookID: 42,
            format: "epub",
            query: query
        )

        XCTAssertEqual(result.totalOccurrences, 1)
        XCTAssertEqual(result.snippets.count, 1)
        let snippet = result.snippets[0].text
        XCTAssertTrue(snippet.contains("\u{1D}love\u{1D}"))
        XCTAssertFalse(snippet.contains("\u{1D}lovely\u{1D}"))
        XCTAssertFalse(snippet.contains("\u{1D}inlove\u{1D}"))
    }
}
