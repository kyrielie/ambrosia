import XCTest
@testable import Ambrosia

/// Plan PR J: `RuleMatchCache`, `bookTagsRevision`, and the cache keys that carry it.
@MainActor
final class RuleMatchCacheTests: XCTestCase {

    private func key(_ value: String) -> RuleMatchKey {
        RuleMatchKey(rule: FilterRule(field: .tag, op: .contains, value: value), tagExpansions: [:])
    }

    func testStoredGlobalSetIsReturned() {
        let cache = RuleMatchCache()
        XCTAssertTrue(cache.store([3, 1, 2], for: key("a"), revision: 0, isGlobal: true))
        XCTAssertEqual(cache.members(for: key("a"), revision: 0), [1, 2, 3])
    }

    func testRestrictedSetCannotBeStored() {
        let cache = RuleMatchCache()
        XCTAssertFalse(cache.store([1], for: key("a"), revision: 0, isGlobal: false))
        XCTAssertNil(cache.members(for: key("a"), revision: 0))
        XCTAssertEqual(cache.count, 0)
    }

    func testEntryIsNotReturnedAfterRevisionChanges() {
        let cache = RuleMatchCache()
        cache.store([1], for: key("a"), revision: 0, isGlobal: true)
        XCTAssertNil(cache.members(for: key("a"), revision: 1))
    }

    func testLimitEvictsOldest() {
        let cache = RuleMatchCache(limit: 2)
        cache.store([1], for: key("a"), revision: 0, isGlobal: true)
        cache.store([2], for: key("b"), revision: 0, isGlobal: true)
        cache.store([3], for: key("c"), revision: 0, isGlobal: true)
        XCTAssertNil(cache.members(for: key("a"), revision: 0))
        XCTAssertNotNil(cache.members(for: key("c"), revision: 0))
    }

    func testRemoveAllClears() {
        let cache = RuleMatchCache()
        cache.store([1], for: key("a"), revision: 0, isGlobal: true)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testFilterResultKeysDifferingOnlyInRevisionAreUnequal() {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .contains, value: "a")], conjunction: .and)]
        let first = FilterResultCacheKey(expression: expr, membershipVersion: 1, visibilitySignature: "s", bookTagsRevision: 0)
        let second = FilterResultCacheKey(expression: expr, membershipVersion: 1, visibilitySignature: "s", bookTagsRevision: 1)
        XCTAssertNotEqual(first, second)
    }

    func testSessionFilterCacheMissesAfterRevisionChange() {
        let session = LibrarySession()
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .contains, value: "a")], conjunction: .and)]
        session.rememberFilterResult(FilterResult(calibreIDs: [1]), for: expr, visibilitySignature: "s")
        XCTAssertNotNil(session.cachedFilterResult(for: expr, visibilitySignature: "s"))
        // A result filed under a stale captured revision is unreachable at the current one.
        session.rememberFilterResult(FilterResult(calibreIDs: [2]), for: expr, visibilitySignature: "t",
                                     bookTagsRevision: 99)
        XCTAssertNil(session.cachedFilterResult(for: expr, visibilitySignature: "t"))
    }

    func testBookTagsRevisionIncrementsOnInsertBatch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleMatchCacheTests-\(UUID().uuidString)")
        let db = try AmbrosiaMetaDB(libraryURL: url)
        let before = await db.bookTagsRevision
        let record = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: nil,
            chapterCurrent: nil, chapterTotal: nil, isComplete: false, language: nil,
            publishedDate: nil, updatedDate: nil, fandoms: ["F"], relationships: [], characters: [],
            additionalTags: ["Fluff"], categories: [], ao3Collections: [], series: [], rating: nil,
            warnings: [], extractedAt: "2024-01-01T00:00:00Z"
        )
        try await db.insertBatch([(record, 1)], diagnostics: [])
        let after = await db.bookTagsRevision
        XCTAssertGreaterThan(after, before)
    }
}
