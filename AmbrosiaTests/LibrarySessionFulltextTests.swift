// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

/// Session-level `fulltext:` cache rules, driven through the `FulltextSearching` seam so no
/// real `full-text-search.db` is needed. `docs/testing.md` records `LibrarySession` as
/// otherwise untested; the seam is deliberately minimal.
/// Scripted result for `StubSearcher`; hoisted to file scope to keep type nesting at one level.
private enum StubSearchOutcome {
    case ids([Int], FTSIndexStamp)
    case failure(FTSSearchError)
}

@MainActor
final class LibrarySessionFulltextTests: XCTestCase {

    /// Scripted backend: returns queued outcomes in order and counts calls.
    private final class StubSearcher: FulltextSearching, @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [StubSearchOutcome]
        private var generation = 0
        private(set) var searchCount = 0

        init(_ outcomes: [StubSearchOutcome]) { self.outcomes = outcomes }

        func beginSearch() -> SearchToken {
            lock.withLock {
                generation += 1
                return SearchToken(generation: generation)
            }
        }
        func cancel(_ token: SearchToken) {}
        func searchBooks(_ query: FTSQuery, token: SearchToken) async throws -> FTSBookSet {
            let outcome = lock.withLock { () -> StubSearchOutcome in
                searchCount += 1
                return outcomes.isEmpty ? StubSearchOutcome.ids([], StubSearcher.stamp(1)) : outcomes.removeFirst()
            }
            switch outcome {
            case let .ids(ids, stamp):
                return FTSBookSet(bookIDs: ids, stamp: stamp, usedSanitizedFallback: false)
            case let .failure(error):
                throw error
            }
        }
        static func stamp(_ dataVersion: Int, inode: UInt64 = 1) -> FTSIndexStamp {
            FTSIndexStamp(device: 1, inode: inode, dataVersion: dataVersion)
        }
    }

    private func makeSession(_ stub: StubSearcher) -> LibrarySession {
        let session = LibrarySession()
        session.fulltextSearcherOverride = stub
        return session
    }

    func testSuccessIsCachedAndServedWithoutASecondSearch() async {
        let stub = StubSearcher([.ids([1, 2, 3], StubSearcher.stamp(1))])
        let session = makeSession(stub)
        let first = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertEqual(first, [1, 2, 3])
        XCTAssertEqual(session.cachedFulltextIDs(for: "dragon"), [1, 2, 3])
        let second = await session.resolveFulltextIDs(for: " dragon ")
        XCTAssertEqual(second, [1, 2, 3])
        XCTAssertEqual(stub.searchCount, 1)
        XCTAssertNil(session.lastFulltextError)
    }

    func testEmptySuccessfulResultIsCached() async {
        let stub = StubSearcher([.ids([], StubSearcher.stamp(1))])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "nothing")
        XCTAssertEqual(session.cachedFulltextIDs(for: "nothing"), [])
    }

    func testFailuresAreNeverCached() async {
        let failures: [FTSSearchError] = [
            .busy, .syntax("fts5: syntax error"), .cancelled,
            .sqlite(code: 1, message: "boom"), .tokenizerUnavailable
        ]
        for failure in failures {
            let session = makeSession(StubSearcher([.failure(failure)]))
            let ids = await session.resolveFulltextIDs(for: "dragon")
            XCTAssertEqual(ids, [], "\(failure)")
            XCTAssertNil(session.cachedFulltextIDs(for: "dragon"), "\(failure) was cached")
        }
    }

    func testBusySetsLastErrorButCancellationDoesNot() async {
        let busy = makeSession(StubSearcher([.failure(.busy)]))
        _ = await busy.resolveFulltextIDs(for: "dragon")
        XCTAssertNotNil(busy.lastFulltextError)

        let cancelled = makeSession(StubSearcher([.failure(.cancelled)]))
        _ = await cancelled.resolveFulltextIDs(for: "dragon")
        XCTAssertNil(cancelled.lastFulltextError)
    }

    func testSuccessAfterFailureClearsLastError() async {
        let stub = StubSearcher([.failure(.busy), .ids([4], StubSearcher.stamp(1))])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertNotNil(session.lastFulltextError)
        // A recorded failure is not retried until the user retries or edits the query.
        session.retryFulltext(for: "dragon")
        let ids = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertEqual(ids, [4])
        XCTAssertNil(session.lastFulltextError)
    }

    func testChangedIndexStampClearsTheCache() async {
        let stub = StubSearcher([
            .ids([1], StubSearcher.stamp(1)),
            .ids([2], StubSearcher.stamp(2))   // Calibre committed in between
        ])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "alpha")
        XCTAssertEqual(session.cachedFulltextIDs(for: "alpha"), [1])
        _ = await session.resolveFulltextIDs(for: "beta")
        XCTAssertNil(session.cachedFulltextIDs(for: "alpha"), "stale entry survived a stamp change")
        XCTAssertEqual(session.cachedFulltextIDs(for: "beta"), [2])
    }

    func testRecreatedFileClearsTheCache() async {
        let stub = StubSearcher([
            .ids([1], StubSearcher.stamp(1, inode: 10)),
            .ids([9], StubSearcher.stamp(1, inode: 11))   // same data_version, new inode (D19)
        ])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "alpha")
        _ = await session.resolveFulltextIDs(for: "beta")
        XCTAssertNil(session.cachedFulltextIDs(for: "alpha"))
    }

    func testUnchangedStampKeepsOtherEntries() async {
        let stub = StubSearcher([.ids([1], StubSearcher.stamp(1)), .ids([2], StubSearcher.stamp(1))])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "alpha")
        _ = await session.resolveFulltextIDs(for: "beta")
        XCTAssertEqual(session.cachedFulltextIDs(for: "alpha"), [1])
    }

    func testEmptyPhraseNeverReachesTheBackend() async {
        let stub = StubSearcher([])
        let session = makeSession(stub)
        let ids = await session.resolveFulltextIDs(for: "   ")
        XCTAssertEqual(ids, [])
        XCTAssertEqual(stub.searchCount, 0)
    }

    func testAccentedAndPlainPhrasesAreSeparateCacheEntries() async {
        let stub = StubSearcher([.ids([1, 2], StubSearcher.stamp(1)), .ids([1], StubSearcher.stamp(1))])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "resume")
        _ = await session.resolveFulltextIDs(for: "r\u{00E9}sum\u{00E9}")
        XCTAssertEqual(session.cachedFulltextIDs(for: "resume"), [1, 2])
        XCTAssertEqual(session.cachedFulltextIDs(for: "r\u{00E9}sum\u{00E9}"), [1])
        XCTAssertEqual(stub.searchCount, 2)
    }

    func testResolvedQueryCarriesIDsAndDropsPlainTerms() async {
        let stub = StubSearcher([.ids([5, 6], StubSearcher.stamp(1))])
        let session = makeSession(stub)
        let query = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [],
                                statusTerms: [], fulltextPhrase: "dragon", plainTerms: ["x"], ftsMatchedIDs: nil)
        let resolved = await session.resolvedQuery(query)
        XCTAssertEqual(resolved.ftsMatchedIDs, [5, 6])
        XCTAssertEqual(resolved.plainTerms, [])
    }

    func testResolvedQueryWithoutPhraseIsReturnedUnchanged() async {
        let session = makeSession(StubSearcher([]))
        let query = SearchQuery(tagTerms: ["a"], authorTerms: [], titleTerms: [], plainTerms: [])
        let resolved = await session.resolvedQuery(query)
        XCTAssertEqual(resolved.tagTerms, ["a"])
        XCTAssertNil(resolved.ftsMatchedIDs)
    }

    // MARK: - Failure state (no UI retry loop)

    func testFailureYieldsFailedStateAndEmptyQueryIDs() async {
        let session = makeSession(StubSearcher([.failure(.busy)]))
        _ = await session.resolveFulltextIDs(for: "dragon")
        guard case .failed = session.fulltextState(for: "dragon") else {
            return XCTFail("expected .failed, got \(session.fulltextState(for: "dragon"))")
        }
        XCTAssertNil(session.cachedFulltextIDs(for: "dragon"))
        let query = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [],
                                statusTerms: [], fulltextPhrase: "dragon", plainTerms: [], ftsMatchedIDs: nil)
        let rewritten = LibraryQueryHelpers.queryWithCachedFullText(query, session: session)
        XCTAssertEqual(rewritten.ftsMatchedIDs, [])
    }

    func testFailedPhraseIsNotSearchedAgain() async {
        let stub = StubSearcher([.failure(.busy)])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "dragon")
        _ = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertEqual(stub.searchCount, 1)
    }

    func testRetryClearsFailureAndSearchesAgain() async {
        let stub = StubSearcher([.failure(.busy), .ids([4], StubSearcher.stamp(1))])
        let session = makeSession(stub)
        _ = await session.resolveFulltextIDs(for: "dragon")
        session.retryFulltext(for: "dragon")
        XCTAssertEqual(session.fulltextState(for: "dragon"), .unknown)
        let ids = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertEqual(ids, [4])
        XCTAssertEqual(stub.searchCount, 2)
        XCTAssertEqual(session.fulltextState(for: "dragon"), .resolved([4]))
    }

    func testCancellationIsNotRecordedAsFailure() async {
        let session = makeSession(StubSearcher([.failure(.cancelled)]))
        _ = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertEqual(session.fulltextState(for: "dragon"), .unknown)
    }

    func testNoSearcherFailsOnceWithIndexMessage() async {
        let session = LibrarySession()
        _ = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertEqual(session.fulltextState(for: "dragon"),
                       .failed(LibrarySession.noFulltextIndexMessage))
        XCTAssertEqual(session.failedFulltextKeys.count, 1)
        _ = await session.resolveFulltextIDs(for: "dragon")
        XCTAssertEqual(session.failedFulltextKeys.count, 1)
    }

    func testUnbuildablePhraseIsResolvedEmptyNotUnknown() {
        let session = LibrarySession()
        XCTAssertEqual(session.fulltextState(for: "   "), .resolved([]))
    }
}
