import XCTest
@testable import Ambrosia

// Cache keys must carry every input that changes cached contents. Toggling a
// visibility preference changes no membership set, so `membershipVersion` and
// `visibilityVersion` cannot distinguish the entries on their own.
@MainActor
final class CacheKeyTests: XCTestCase {

    private func pageKey(_ policy: LibraryVisibilityPolicy) -> PageCacheKey {
        PageCacheKey(
            querySignature: "q", filterSignature: "f", tagExpansionsDigest: "",
            visibilityVersion: 3, visibilitySignature: policy.cacheSignature,
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

    func testFilterResultKeyDiffersByEachPref() {
        let base = FilterResultCacheKey(expression: expression(), membershipVersion: 1, visibilitySignature: signature())
        let variants = [
            signature(skip: false), signature(pub: true), signature(anth: true), signature(dup: true)
        ].map { FilterResultCacheKey(expression: expression(), membershipVersion: 1, visibilitySignature: $0) }
        for variant in variants { XCTAssertNotEqual(base, variant) }
        XCTAssertEqual(Set(variants + [base]).count, 5)
    }

    func testFilterResultKeyEqualForIdenticalInputs() {
        let first = FilterResultCacheKey(expression: expression(), membershipVersion: 1, visibilitySignature: signature())
        let second = FilterResultCacheKey(expression: expression(), membershipVersion: 1, visibilitySignature: signature())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    func testSessionFilterCacheMissesAfterPrefChange() {
        let session = LibrarySession()
        let result = FilterResult(calibreIDs: [1, 2], totalCount: 2)
        session.rememberFilterResult(result, for: expression(), visibilitySignature: signature())
        XCTAssertNotNil(session.cachedFilterResult(for: expression(), visibilitySignature: signature()))
        XCTAssertNil(session.cachedFilterResult(for: expression(), visibilitySignature: signature(anth: true)))
    }
}
