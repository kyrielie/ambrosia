import XCTest
@testable import Ambrosia

// Covers SearchQueryParser.parse and SearchQuery.asSingleFilterRule -- the
// search-bar prefix grammar documented at the top of SearchQueryParser.swift
// (tag:/author:/title:/series:/status:/fulltext:/plain text). Pure, no
// actor/DB dependency, driven directly.
//
// Note: FilterRule's `id` is a fresh UUID per init and is included in its
// synthesized Equatable conformance, so asserting against a freshly built
// FilterRule with XCTAssertEqual would spuriously fail on `id` alone --
// these tests compare `.field`/`.op`/`.value` individually instead.
final class SearchQueryParserTests: XCTestCase {

    // MARK: - Prefix parsing

    func test_tagPrefix_capturesEverythingAfterColonIncludingSpaces() {
        let query = SearchQueryParser.parse("tag:Middle School AU")
        XCTAssertEqual(query.tagTerms, ["Middle School AU"])
        XCTAssertTrue(query.authorTerms.isEmpty)
        XCTAssertTrue(query.plainTerms.isEmpty)
    }

    func test_authorPrefix_isCaseInsensitive() {
        let query = SearchQueryParser.parse("AUTHOR:someone")
        XCTAssertEqual(query.authorTerms, ["someone"])
    }

    func test_seriesPrefix() {
        let query = SearchQueryParser.parse("series:Some Series Name")
        XCTAssertEqual(query.seriesTerms, ["Some Series Name"])
    }

    func test_statusPrefix() {
        let query = SearchQueryParser.parse("status:Complete")
        XCTAssertEqual(query.statusTerms, ["Complete"])
    }

    func test_fulltextPrefix() {
        let query = SearchQueryParser.parse("fulltext:dragon egg")
        XCTAssertEqual(query.fulltextPhrase, "dragon egg")
    }

    func test_titlePrefix() {
        let query = SearchQueryParser.parse("title:A Study in Scarlet")
        XCTAssertEqual(query.titleTerms, ["A Study in Scarlet"])
    }

    func test_noPrefix_splitsPlainTextIntoWords() {
        let query = SearchQueryParser.parse("dragon egg hunt")
        XCTAssertEqual(query.plainTerms, ["dragon", "egg", "hunt"])
    }

    func test_emptyPrefixValue_fallsThroughToPlainTermsAsSingleWord() {
        // "tag:" alone has an empty value, so the parser's `!value.isEmpty`
        // guard should skip it and fall through to plain-word parsing.
        let query = SearchQueryParser.parse("tag:")
        XCTAssertTrue(query.tagTerms.isEmpty)
        XCTAssertEqual(query.plainTerms, ["tag:"])
    }

    func test_whitespaceIsTrimmedBeforeParsing() {
        let query = SearchQueryParser.parse("   tag:horror   ")
        XCTAssertEqual(query.tagTerms, ["horror"])
    }

    // MARK: - Trailing-prefix warning (only one prefix parsed per string)

    func test_secondPrefixInValue_setsTrailingPrefixWarning() {
        let query = SearchQueryParser.parse("tag:horror author:smith")
        // The whole remainder after "tag:" becomes the tag value; the
        // embedded "author:" is flagged, not parsed as a second rule.
        XCTAssertEqual(query.tagTerms, ["horror author:smith"])
        XCTAssertTrue(query.hasTrailingPrefixWarning)
    }

    func test_noEmbeddedPrefix_noWarning() {
        let query = SearchQueryParser.parse("tag:horror")
        XCTAssertFalse(query.hasTrailingPrefixWarning)
    }

    // MARK: - activePrefixValue (autocomplete helper)

    func test_activePrefixValue_returnsTypedSuffix() {
        XCTAssertEqual("tag:Middle Sc".activePrefixValue(for: "tag:"), "Middle Sc")
    }

    func test_activePrefixValue_returnsNilWhenPrefixAbsent() {
        XCTAssertNil("Middle Sc".activePrefixValue(for: "tag:"))
    }

    // MARK: - asSingleFilterRule

    func test_asSingleFilterRule_plainTag_usesEqualsOnTagField() {
        let query = SearchQueryParser.parse("tag:Fluff")
        let rule = query.asSingleFilterRule()
        XCTAssertEqual(rule?.field, .tag)
        XCTAssertEqual(rule?.op, .equals)
        XCTAssertEqual(rule?.value, "Fluff")
    }

    func test_asSingleFilterRule_ratingTag_usesRatingAtMostOnRatingField() {
        // AO3Rating raw values are exact strings like "Explicit" -- see
        // AO3Metadata.swift's AO3TagKind.classify.
        let query = SearchQueryParser.parse("tag:Explicit")
        let rule = query.asSingleFilterRule()
        XCTAssertEqual(rule?.field, .rating)
        XCTAssertEqual(rule?.op, .ratingAtMost)
        XCTAssertEqual(rule?.value, "Explicit")
    }

    func test_asSingleFilterRule_usesResolvedTagTermWhenProvided() {
        let query = SearchQueryParser.parse("tag:fluffy")
        let rule = query.asSingleFilterRule(resolvedTagTerm: "Fluff and Snuggles")
        XCTAssertEqual(rule?.value, "Fluff and Snuggles")
    }

    func test_asSingleFilterRule_author_usesEqualsOnAuthorNameField() {
        let query = SearchQueryParser.parse("author:someone")
        let rule = query.asSingleFilterRule()
        XCTAssertEqual(rule?.field, .authorName)
        XCTAssertEqual(rule?.op, .equals)
        XCTAssertEqual(rule?.value, "someone")
    }

    func test_asSingleFilterRule_title_usesContainsOnTitleField() {
        let query = SearchQueryParser.parse("title:Scarlet")
        let rule = query.asSingleFilterRule()
        XCTAssertEqual(rule?.field, .title)
        XCTAssertEqual(rule?.op, .contains)
    }

    func test_asSingleFilterRule_validStatus_producesStatusRule() {
        let query = SearchQueryParser.parse("status:wip")
        let rule = query.asSingleFilterRule()
        XCTAssertEqual(rule?.field, .status)
        XCTAssertEqual(rule?.value, AO3CompletionStatus.workInProgress.rawValue)
    }

    func test_asSingleFilterRule_invalidStatus_returnsNil() {
        let query = SearchQueryParser.parse("status:not-a-real-status")
        XCTAssertNil(query.asSingleFilterRule())
    }

    func test_asSingleFilterRule_fulltext_usesContainsOnFulltextField() {
        let query = SearchQueryParser.parse("fulltext:dragon egg")
        let rule = query.asSingleFilterRule()
        XCTAssertEqual(rule?.field, .fulltext)
        XCTAssertEqual(rule?.value, "dragon egg")
    }

    func test_asSingleFilterRule_plainTextQuery_returnsNil() {
        // Plain (unprefixed) fuzzy title search has no single-rule
        // equivalent -- it's handled elsewhere in the search pipeline, not
        // via asSingleFilterRule.
        let query = SearchQueryParser.parse("dragon egg hunt")
        XCTAssertNil(query.asSingleFilterRule())
    }
}
