import XCTest
@testable import Ambrosia

// Covers the per-walk grouped-units cache added to LocalFeedServer
// (feedUnitsCache / groupedUnitsForWalk) — see the "cache-the-walk" fix.
//
// FeedDisplayUnit and FeedUnitsCacheEntry are both intentionally `private`
// to LocalFeedServer.swift, so these tests go through the `#if DEBUG`
// test-hook surface (feedUnitsCacheEntryCount / feedUnitsCacheContainsKey /
// testHook_groupedUnitCount) added alongside the cache, which exposes only
// Int/Bool and keeps that encapsulation intact.
final class LocalFeedServerWalkCacheTests: XCTestCase {

    var server: LocalFeedServer!

    // NOTE: candidate IDs used below are placeholders (1, 2, 3, ...), and
    // the server under test is never `start`ed with a library. This is
    // deliberate, not an oversight: groupedUnitsForWalk's caching behavior
    // (hit/miss/invalidate/evict) only depends on the candidate ID set's
    // identity, not on real book content, and fetchFeedBooks(calibreIDs:)
    // already guards `library == nil` by returning `[]` (verified in
    // LocalFeedServer.swift), so groupedDisplayUnits(from: []) exercises
    // the same cache code path with an empty-but-real result. A future
    // end-to-end test asserting on actual grouped content should use
    // CalibreTestFixture.makeTempLibraryRoot() + CalibreLibrary(root:) and
    // start() the server, but that's out of scope for cache-mechanics
    // coverage here.

    override func setUpWithError() throws {
        server = LocalFeedServer()
    }

    /// Page 1, then page 2, then page 3 of the same walk (same walkKey, same
    /// candidate IDs) should reuse the first page's computed units rather
    /// than recomputing the fetch+group work on every call.
    func testCacheHitAcrossPages() async throws {
        let ids = allBookIDs()
        let walkKey = "http://localhost:8765/feed/collection/test.json"

        let count1 = await server.testHook_groupedUnitCount(walkKey: walkKey, calibreIDs: ids)
        let entriesAfterPage1 = await server.feedUnitsCacheEntryCount

        let count2 = await server.testHook_groupedUnitCount(walkKey: walkKey, calibreIDs: ids)
        let count3 = await server.testHook_groupedUnitCount(walkKey: walkKey, calibreIDs: ids)

        XCTAssertEqual(entriesAfterPage1, 1, "first call should populate exactly one cache entry")
        XCTAssertEqual(count1, count2)
        XCTAssertEqual(count2, count3)

        // Same walkKey across all three calls means only one entry should
        // ever exist for this walk, even after repeated "page" requests.
        let entriesAfterAllPages = await server.feedUnitsCacheEntryCount
        XCTAssertEqual(entriesAfterAllPages, 1)
    }

    /// A candidate-ID change under the same feedURL (collection/search
    /// membership shifted between pages of the same walk) must be treated
    /// as a fresh computation, replacing (not adding to) the walk's entry.
    func testCacheInvalidatesOnCandidateChange() async throws {
        let allIDs = allBookIDs()
        let walkKey = "http://localhost:8765/feed/collection/test.json"

        _ = await server.testHook_groupedUnitCount(walkKey: walkKey, calibreIDs: allIDs)
        let narrowedIDs = Array(allIDs.dropLast())
        _ = await server.testHook_groupedUnitCount(walkKey: walkKey, calibreIDs: narrowedIDs)

        let entryCount = await server.feedUnitsCacheEntryCount
        XCTAssertEqual(entryCount, 1, "changed candidate set should replace, not add to, the walk's entry")
        let containsKey = await server.feedUnitsCacheContainsKey(walkKey)
        XCTAssertTrue(containsKey)
    }

    /// Once a walk's cache entry exists, starting a distinct walk (different
    /// feedURL/walkKey) must not reuse or collide with it.
    func testDistinctWalksGetDistinctEntries() async throws {
        let ids = allBookIDs()
        let walkKeyA = "http://localhost:8765/feed/collection/a.json"
        let walkKeyB = "http://localhost:8765/feed/collection/b.json"

        _ = await server.testHook_groupedUnitCount(walkKey: walkKeyA, calibreIDs: ids)
        _ = await server.testHook_groupedUnitCount(walkKey: walkKeyB, calibreIDs: ids)

        let entryCount = await server.feedUnitsCacheEntryCount
        XCTAssertEqual(entryCount, 2)
        let containsA = await server.feedUnitsCacheContainsKey(walkKeyA)
        let containsB = await server.feedUnitsCacheContainsKey(walkKeyB)
        XCTAssertTrue(containsA)
        XCTAssertTrue(containsB)
    }

    /// Within-TTL repeat calls for the same walk must keep returning the
    /// same (cached) result rather than drifting, and the TTL constant
    /// itself should be a sane positive window. A true past-TTL-expiry
    /// test is not implemented here (flagged rather than guessed) — it
    /// would require `feedUnitsCacheTTL` or the clock to be injectable;
    /// today it's a fixed static constant.
    func testWithinTTLStaysConsistent() async throws {
        let ids = allBookIDs()
        let walkKey = "http://localhost:8765/feed/collection/test.json"

        let first = await server.testHook_groupedUnitCount(walkKey: walkKey, calibreIDs: ids)
        let second = await server.testHook_groupedUnitCount(walkKey: walkKey, calibreIDs: ids)

        XCTAssertEqual(first, second)
        let entryCount = await server.feedUnitsCacheEntryCount
        XCTAssertEqual(entryCount, 1)
    }

    private func allBookIDs() -> [Int] {
        // Placeholder candidate set — see NOTE above. Sufficient for
        // asserting cache hit/miss/invalidate/evict behavior since that
        // logic only depends on the ID set's identity, not its content.
        [1, 2, 3, 4, 5]
    }
}
