import XCTest
@testable import Ambrosia

/// Coverage for `LibraryFilterDebug.summary(expression:)` / `.summary(query:)`
/// and `FilterSummary.humanReadable(expression:)` (`FilterBuilder.swift:126-177`).
///
/// `LibraryFilterDebug.summary(query:)` double-duties as the cache-key digest
/// `docs/caching.md` describes, so the exact join format and omission of
/// empty/nil fields pinned here matters beyond debug logging.
final class LibraryFilterDebugSummaryTests: XCTestCase {

    // MARK: - summary(expression:)

    func testSummaryExpressionJoinsCompleteRulesCommaSeparated() {
        var expression = FilterExpression()
        expression.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .contains, value: "Fantasy"),
                FilterRule(field: .authorName, op: .equals, value: "Smith")
            ])
        ]
        let summary = LibraryFilterDebug.summary(expression: expression)
        XCTAssertEqual(summary, "tag.contains=Fantasy,authorName.equals=Smith")
    }

    func testSummaryExpressionExcludesIncompleteRules() {
        var expression = FilterExpression()
        expression.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .contains, value: "Fantasy"),
                FilterRule(field: .authorName, op: .equals, value: "") // incomplete: empty value
            ])
        ]
        let summary = LibraryFilterDebug.summary(expression: expression)
        XCTAssertEqual(summary, "tag.contains=Fantasy")
    }

    func testSummaryExpressionAcrossMultipleGroups() {
        var expression = FilterExpression()
        expression.groups = [
            FilterGroup(rules: [FilterRule(field: .tag, op: .contains, value: "Fantasy")]),
            FilterGroup(rules: [FilterRule(field: .rating, op: .equals, value: "Explicit")])
        ]
        let summary = LibraryFilterDebug.summary(expression: expression)
        XCTAssertEqual(summary, "tag.contains=Fantasy,rating.equals=Explicit")
    }

    // MARK: - summary(query:)

    func testSummaryQueryEachPopulatedField() {
        let tagOnly = SearchQuery(tagTerms: ["Fantasy", "Romance"], authorTerms: [], titleTerms: [], seriesTerms: [], plainTerms: [])
        XCTAssertEqual(LibraryFilterDebug.summary(query: tagOnly), "tag:Fantasy|Romance")

        let authorOnly = SearchQuery(tagTerms: [], authorTerms: ["Smith"], titleTerms: [], seriesTerms: [], plainTerms: [])
        XCTAssertEqual(LibraryFilterDebug.summary(query: authorOnly), "author:Smith")

        let titleOnly = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: ["Dawn"], seriesTerms: [], plainTerms: [])
        XCTAssertEqual(LibraryFilterDebug.summary(query: titleOnly), "title:Dawn")

        let seriesOnly = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: ["Chronicles"], plainTerms: [])
        XCTAssertEqual(LibraryFilterDebug.summary(query: seriesOnly), "series:Chronicles")

        let plainOnly = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], plainTerms: ["hello", "world"])
        XCTAssertEqual(LibraryFilterDebug.summary(query: plainOnly), "plain:hello|world")

        let fulltextOnly = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], statusTerms: [], fulltextPhrase: "a phrase", plainTerms: [])
        XCTAssertEqual(LibraryFilterDebug.summary(query: fulltextOnly), "fulltext:a phrase")

        var ftsOnly = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], plainTerms: [])
        ftsOnly.ftsMatchedIDs = [1, 2, 3]
        XCTAssertEqual(LibraryFilterDebug.summary(query: ftsOnly), "ftsIDs:3")
    }

    func testSummaryQueryOmitsEmptyAndNilFields() {
        let empty = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], plainTerms: [])
        XCTAssertEqual(LibraryFilterDebug.summary(query: empty), "")
    }

    func testSummaryQueryCombinesMultiplePopulatedFields() {
        let query = SearchQuery(tagTerms: ["Fantasy"], authorTerms: ["Smith"], titleTerms: [], seriesTerms: [], plainTerms: [])
        XCTAssertEqual(LibraryFilterDebug.summary(query: query), "tag:Fantasy,author:Smith")
    }

    // MARK: - FilterSummary.humanReadable(expression:)

    func testHumanReadableEmptyExpressionIsAllBooks() {
        let expression = FilterExpression()
        XCTAssertEqual(FilterSummary.humanReadable(expression: expression), "All books")
    }

    func testHumanReadableJoinerSelection() {
        var andExpr = FilterExpression()
        andExpr.groups = [FilterGroup(
            rules: [
                FilterRule(field: .tag, op: .contains, value: "Fantasy"),
                FilterRule(field: .tag, op: .contains, value: "Romance")
            ],
            conjunction: .and
        )]
        XCTAssertEqual(FilterSummary.humanReadable(expression: andExpr), "Tag contains Fantasy and Tag contains Romance")

        var orExpr = FilterExpression()
        orExpr.groups = [FilterGroup(
            rules: [
                FilterRule(field: .tag, op: .contains, value: "Fantasy"),
                FilterRule(field: .tag, op: .contains, value: "Romance")
            ],
            conjunction: .or
        )]
        XCTAssertEqual(FilterSummary.humanReadable(expression: orExpr), "Tag contains Fantasy or Tag contains Romance")
    }

    func testHumanReadableGroupConjunctionJoinsGroups() {
        var expression = FilterExpression()
        expression.groups = [
            FilterGroup(rules: [FilterRule(field: .tag, op: .contains, value: "Fantasy")]),
            FilterGroup(rules: [FilterRule(field: .rating, op: .equals, value: "Explicit")])
        ]
        expression.groupConjunction = .and
        XCTAssertEqual(FilterSummary.humanReadable(expression: expression), "Tag contains Fantasy and Rating is Explicit")
    }

    func testHumanReadableRatingLabelSpecialCase() {
        var expression = FilterExpression()
        expression.groups = [FilterGroup(rules: [FilterRule(field: .rating, op: .ratingAtLeast, value: "Explicit")])]
        // rule.op.label.contains("rating") -> "min rating Explicit", not "Rating min rating Explicit".
        XCTAssertEqual(FilterSummary.humanReadable(expression: expression), "min rating Explicit")
    }

    func testHumanReadableTruncatesAt80CharsWithEllipsis() {
        var expression = FilterExpression()
        // Each rule renders as "Tag contains <value>" (~20 chars); enough rules
        // joined by " and " comfortably exceeds the 80-char maxLength.
        let rules = (0..<10).map { FilterRule(field: .tag, op: .contains, value: "Fantasy\($0)") }
        expression.groups = [FilterGroup(rules: rules, conjunction: .and)]
        let full = rules.map { "Tag contains \($0.value)" }.joined(separator: " and ")
        XCTAssertGreaterThan(full.count, 80) // sanity: input actually exceeds maxLength

        let result = FilterSummary.humanReadable(expression: expression)
        XCTAssertTrue(result.hasSuffix("…"))
        // Content before the ellipsis is the 80-char prefix of `full`, trimmed of
        // trailing whitespace -- never longer than 80, and it's a true prefix.
        let content = String(result.dropLast())
        XCTAssertLessThanOrEqual(content.count, 80)
        XCTAssertTrue(full.hasPrefix(content))
    }
}
