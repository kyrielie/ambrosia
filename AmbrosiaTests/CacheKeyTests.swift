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
}
