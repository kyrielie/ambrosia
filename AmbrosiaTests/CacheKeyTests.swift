import XCTest
@testable import Ambrosia

// Cache keys carry visibility and pinned collection inputs independently.
@MainActor
final class CacheKeyTests: XCTestCase {

    private func pageKey(_ policy: LibraryVisibilityPolicy, pinnedCollectionVersion: Int = 4) -> PageCacheKey {
        PageCacheKey(
            querySignature: "q", filterSignature: "f", tagExpansionsDigest: "",
            visibilityVersion: 3, pinnedCollectionVersion: pinnedCollectionVersion,
            visibilitySignature: policy.cacheSignature,
            sortField: .wordCount, ascending: true, randomSeed: 1, offset: 0, limit: 76
        )
    }

    private func expression() -> FilterExpression {
        var expression = FilterExpression()
        expression.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .equals, value: "fluff")], conjunction: .and)]
        expression.groupConjunction = .and
        return expression
    }

    private func signature(skip: Bool = true, pub: Bool = false, anth: Bool = false, dup: Bool = false) -> String {
        LibraryVisibilityPolicy.signature(showSkippedCollection: skip, hideNonAO3PublisherBooks: pub,
                                          hideAnthologyBooks: anth, hideDuplicateBooks: dup)
    }

    func testPageKeyDiffersWhenHideAnthologyDiffers() {
        var other = LibraryVisibilityPolicy.allowAll
        other.hideAnthologyBooks = true
        XCTAssertNotEqual(pageKey(.allowAll), pageKey(other))
    }

    func testPageKeyDiffersWhenGroupingDiffers() {
        var other = LibraryVisibilityPolicy.allowAll
        other.shouldGroupSeriesRows = true
        XCTAssertNotEqual(pageKey(.allowAll), pageKey(other))
    }

    func testPageKeyDiffersForEachRemainingPref() {
        var skipped = LibraryVisibilityPolicy.allowAll
        skipped.showSkippedCollection = false
        var publisher = LibraryVisibilityPolicy.allowAll
        publisher.hideNonAO3PublisherBooks = true
        var duplicates = LibraryVisibilityPolicy.allowAll
        duplicates.hideDuplicateBooks = true
        let keys: Set<PageCacheKey> = [pageKey(.allowAll), pageKey(skipped), pageKey(publisher), pageKey(duplicates)]
        XCTAssertEqual(keys.count, 4)
    }

    func testPageKeyEqualAndHashEqualForIdenticalInputs() {
        let first = pageKey(.allowAll)
        let second = pageKey(.allowAll)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    func testPageKeyDiffersWhenCollectionSnapshotIsRepinned() {
        XCTAssertNotEqual(pageKey(.allowAll), pageKey(.allowAll, pinnedCollectionVersion: 5))
    }

    func testFilterResultKeyDiffersByEachPref() {
        let base = FilterResultCacheKey(expression: expression(), visibilityVersion: 1, pinnedCollectionVersion: 1, visibilitySignature: signature())
        let variants = [
            signature(skip: false), signature(pub: true), signature(anth: true), signature(dup: true)
        ].map { FilterResultCacheKey(expression: expression(), visibilityVersion: 1, pinnedCollectionVersion: 1, visibilitySignature: $0) }
        for variant in variants { XCTAssertNotEqual(base, variant) }
        XCTAssertEqual(Set(variants + [base]).count, 5)
    }

    func testFilterResultKeyEqualForIdenticalInputs() {
        let first = FilterResultCacheKey(expression: expression(), visibilityVersion: 1,
                                         pinnedCollectionVersion: 2, visibilitySignature: signature())
        let second = FilterResultCacheKey(expression: expression(), visibilityVersion: 1,
                                          pinnedCollectionVersion: 2, visibilitySignature: signature())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    func testFilterResultKeyDiffersWhenCollectionSnapshotIsRepinned() {
        let first = FilterResultCacheKey(expression: expression(), visibilityVersion: 1,
                                         pinnedCollectionVersion: 2, visibilitySignature: signature())
        let second = FilterResultCacheKey(expression: expression(), visibilityVersion: 1,
                                          pinnedCollectionVersion: 3, visibilitySignature: signature())
        XCTAssertNotEqual(first, second)
    }

    func testSessionFilterCacheMissesAfterPrefChange() {
        let session = LibrarySession()
        let result = FilterResult(calibreIDs: [1, 2], totalCount: 2)
        session.rememberFilterResult(result, for: expression(), visibilitySignature: signature())
        XCTAssertNotNil(session.cachedFilterResult(for: expression(), visibilitySignature: signature()))
        XCTAssertNil(session.cachedFilterResult(for: expression(), visibilitySignature: signature(anth: true)))
    }

    func testSessionFilterCacheUsesPinnedCollectionVersion() {
        let session = LibrarySession()
        let result = FilterResult(calibreIDs: [1], totalCount: 1)
        session.rememberFilterResult(
            result, for: expression(), visibilitySignature: signature(), pinnedCollectionVersion: 4
        )

        XCTAssertNotNil(session.cachedFilterResult(
            for: expression(), visibilitySignature: signature(), pinnedCollectionVersion: 4
        ))
        XCTAssertNil(session.cachedFilterResult(
            for: expression(), visibilitySignature: signature(), pinnedCollectionVersion: 5
        ))
    }

    func testDigestChangesWithTargetsAndOrderedFlag() {
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let targetsA = TagRelevanceTargets(exact: ["Fluff"], contains: [])
        let targetsB = TagRelevanceTargets(exact: ["Angst"], contains: [])

        let digestDefault = QueryDigestBuilder.digest(query: emptyQuery)
        let digestTargetsA = QueryDigestBuilder.digest(query: emptyQuery, relevanceTargets: targetsA)
        let digestTargetsB = QueryDigestBuilder.digest(query: emptyQuery, relevanceTargets: targetsB)
        let digestUnordered = QueryDigestBuilder.digest(query: emptyQuery, rankedIDsAreOrdered: false)

        XCTAssertNotEqual(digestDefault, digestTargetsA)
        XCTAssertNotEqual(digestTargetsA, digestTargetsB)
        XCTAssertNotEqual(digestDefault, digestUnordered)
    }

    // MARK: - Invariant 30 & Position Filter Cache Keys

    func testRuleMatchKeyDiffersByLimitAndVariants() {
        let rule1 = FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 1, matchVariants: false)
        let rule2 = FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 3, matchVariants: false)
        let rule3 = FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 1, matchVariants: true)

        let key1 = RuleMatchKey(rule: rule1, tagExpansions: [:])
        let key2 = RuleMatchKey(rule: rule2, tagExpansions: [:])
        let key3 = RuleMatchKey(rule: rule3, tagExpansions: [:])

        XCTAssertNotEqual(key1, key2, "Keys must differ when limit differs")
        XCTAssertNotEqual(key1, key3, "Keys must differ when matchVariants differs")
    }

    func testFilterResultCacheKeyDiffersByLimitAndVariants() {
        var expr1 = FilterExpression()
        expr1.groups = [FilterGroup(rules: [
            FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 1, matchVariants: false)
        ])]

        var expr2 = FilterExpression()
        expr2.groups = [FilterGroup(rules: [
            FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 3, matchVariants: false)
        ])]

        var expr3 = FilterExpression()
        expr3.groups = [FilterGroup(rules: [
            FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 1, matchVariants: true)
        ])]

        let key1 = FilterResultCacheKey(expression: expr1, visibilityVersion: 1, pinnedCollectionVersion: 1)
        let key2 = FilterResultCacheKey(expression: expr2, visibilityVersion: 1, pinnedCollectionVersion: 1)
        let key3 = FilterResultCacheKey(expression: expr3, visibilityVersion: 1, pinnedCollectionVersion: 1)

        XCTAssertNotEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
    }

    func testFilterSignatureDiffersByLimitAndVariants() {
        var expr1 = FilterExpression()
        expr1.groups = [FilterGroup(rules: [
            FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 1, matchVariants: false)
        ])]

        var expr2 = FilterExpression()
        expr2.groups = [FilterGroup(rules: [
            FilterRule(field: .firstRelationship, op: .equals, value: "A/B", limit: 2, matchVariants: false)
        ])]

        let sig1 = LibraryFilterDebug.summary(expression: expr1)
        let sig2 = LibraryFilterDebug.summary(expression: expr2)
        XCTAssertNotEqual(sig1, sig2)
        XCTAssertTrue(sig1.contains("n=1"))
        XCTAssertTrue(sig2.contains("n=2"))
    }
}
