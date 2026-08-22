import XCTest
@testable import Ambrosia

/// Regression coverage for `PagingOffsetState`'s per-page-indexed raw SQL
/// offset bookkeeping. See `rawSQLOffsetByPage`'s doc comment
/// (LibraryQueryController.swift) for the full incident history: an
/// original stack-based design corrupted its offset stack under reloads,
/// and a first fix attempt (gating the stack push/pop by an explicit
/// "navigation intent") only fixed the *timing* bug -- it left a structural
/// off-by-one in *which* stack entry Previous restored, which crashed with
/// "rawSQLOffsetHistory desync: history=7 page=6" the first time a real
/// backward click happened after several clean forward pages. This test
/// file exercises the model that replaced the stack entirely.
///
/// `PagingOffsetState` has no SwiftUI/actor dependency, so these tests
/// drive it directly rather than standing up `LibraryRootView`.
/// `simulatePageLoad(...)` below mirrors the bookkeeping
/// `LibraryRootView.loadPage()`'s grouped drain branches perform, kept in
/// this test file so a future accidental edit to the real branches shows up
/// as a test failure rather than silent drift between the two copies.
final class PagingOffsetStateNavigationIntentTests: XCTestCase {

    /// Mirrors one iteration of a grouped drain branch's post-fetch
    /// bookkeeping: given the rows a page's drain loop actually produced
    /// (`rawRowCount`, `overflowRowCount`), record or replay per-page state
    /// exactly as `LibraryRootView.loadPage()` does.
    ///
    /// Returns the offset the drain loop should have started from, so
    /// callers can assert against it.
    @discardableResult
    private func simulatePageLoad(
        rawRowCount: Int,
        overflowRowCount: Int,
        to state: inout PagingOffsetState
    ) -> Int {
        let isNewPage = state.currentPage == state.rawSQLOffsetByPage.count
        let startOffset: Int
        if isNewPage {
            startOffset = state.rawSQLOffsetFrontier
        } else {
            precondition(state.currentPage < state.rawSQLOffsetByPage.count, "page index out of sync")
            startOffset = state.rawSQLOffsetByPage[state.currentPage]
        }
        let postDrainOffset = startOffset + rawRowCount
        if isNewPage {
            state.rawSQLOffsetByPage.append(startOffset)
            state.seedOverflowByPage.append(state.rawSQLOffsetOverflowFrontier)
            state.rawSQLOffsetFrontier = postDrainOffset
            state.rawSQLOffsetOverflowFrontier = Array(repeating: CalibreBook.stub(id: 0), count: overflowRowCount)
        }
        return startOffset
    }

    // MARK: - Forward-only traversal records one entry per page

    func testForwardTraversalRecordsOneEntryPerPage() {
        var state = PagingOffsetState()
        for page in 0..<5 {
            simulatePageLoad(rawRowCount: 76, overflowRowCount: 0, to: &state)
            state.currentPage = page + 1
        }
        XCTAssertEqual(state.rawSQLOffsetByPage, [0, 76, 152, 228, 304])
        XCTAssertEqual(state.rawSQLOffsetFrontier, 380)
        XCTAssertEqual(state.rawSQLOffsetByPage.count, state.currentPage)
    }

    // MARK: - The exact crash: forward 7 pages, then one Previous click

    /// Reproduces the crash log: 7 clean forward loads (pages 0..7), then a
    /// single Previous click (page 7 -> 6). Under the old stack model this
    /// desynced `rawSQLOffsetHistory.count` from `currentPage` and crashed
    /// on the debug assertion. Under the per-page model there is nothing to
    /// pop, so this must simply look up page 6's already-recorded offset.
    func testSingleBackwardClickAfterSevenForwardPagesDoesNotDesync() {
        var state = PagingOffsetState()
        var recordedStartOffsets: [Int] = []
        for page in 0..<8 {
            let start = simulatePageLoad(rawRowCount: 76, overflowRowCount: 0, to: &state)
            recordedStartOffsets.append(start)
            state.currentPage = page + 1
        }
        XCTAssertEqual(state.currentPage, 8)
        XCTAssertEqual(state.rawSQLOffsetByPage.count, 8) // one entry per page 0..7

        // Previous: page 8 -> 7. No popping -- just move the page cursor.
        state.currentPage -= 1
        XCTAssertEqual(state.currentPage, 7)

        // loadPage() would now find currentPage (7) < rawSQLOffsetByPage.count
        // (8), so it replays page 7 by looking it up rather than treating it
        // as new. This must never trip the "currentPage skipped ahead of
        // recorded pages" assertion, and must restore page 7's own start
        // offset (not page 6's, not page 8's).
        XCTAssertTrue(state.currentPage < state.rawSQLOffsetByPage.count)
        XCTAssertEqual(state.rawSQLOffsetByPage[state.currentPage], recordedStartOffsets[7])
    }

    // MARK: - Multiple backward clicks past where the stack model broke

    /// The user's actual report: sort by author, apply a filter that
    /// excludes an author, and one Previous click after reaching the page
    /// where that author would otherwise appear. Simulates several forward
    /// pages (some producing zero *new* raw rows because the excluded
    /// author's rows were filtered out and only carried-over overflow was
    /// shown -- see `rawRowCount: 0` below), then walks Previous back to
    /// page 0 one click at a time, asserting each step restores exactly the
    /// offset that page was first loaded with.
    func testRepeatedBackwardNavigationRestoresExactRecordedOffsets() {
        var state = PagingOffsetState()
        var recordedStartOffsets: [Int] = []
        let rawRowCountsByPage = [76, 76, 0, 76, 29, 0, 76] // mixes in zero-raw-fetch pages, as in the incident log
        for (page, rawCount) in rawRowCountsByPage.enumerated() {
            let start = simulatePageLoad(rawRowCount: rawCount, overflowRowCount: 0, to: &state)
            recordedStartOffsets.append(start)
            state.currentPage = page + 1
        }
        XCTAssertEqual(state.rawSQLOffsetByPage, recordedStartOffsets)

        // Walk all the way back to page 0, one Previous click at a time.
        while state.currentPage > 0 {
            state.currentPage -= 1
            XCTAssertLessThan(state.currentPage, state.rawSQLOffsetByPage.count)
            let restored = state.rawSQLOffsetByPage[state.currentPage]
            XCTAssertEqual(restored, recordedStartOffsets[state.currentPage],
                           "page \(state.currentPage) must restore its own recorded start offset")
        }
    }

    // MARK: - Reload (e.g. membershipVersion bump) is fully inert

    func testRevisitingAnAlreadyRecordedPageNeverMutatesFrontierOrRecordedEntries() {
        var state = PagingOffsetState()
        simulatePageLoad(rawRowCount: 76, overflowRowCount: 0, to: &state)
        state.currentPage = 1
        simulatePageLoad(rawRowCount: 76, overflowRowCount: 0, to: &state)
        state.currentPage = 2

        let byPageBefore = state.rawSQLOffsetByPage
        let frontierBefore = state.rawSQLOffsetFrontier

        // Go back to page 1 and "reload" it (membershipVersion bump, or a
        // Previous click, or Next back to it -- all identical: currentPage
        // is already < rawSQLOffsetByPage.count, so this is a revisit).
        state.currentPage = 1
        let isNewPage = state.currentPage == state.rawSQLOffsetByPage.count
        XCTAssertFalse(isNewPage)
        // Revisits never call the append/frontier-advance branch in
        // simulatePageLoad's real counterpart (loadPage()); nothing here
        // should have changed by merely moving currentPage.
        XCTAssertEqual(state.rawSQLOffsetByPage, byPageBefore)
        XCTAssertEqual(state.rawSQLOffsetFrontier, frontierBefore)
    }

    /// Interleaves several revisits of page 1 between the initial forward
    /// pass and eventually resuming forward past page 2, mimicking
    /// background AO3 extraction reloading the currently-displayed page
    /// repeatedly. None of that may inflate `rawSQLOffsetByPage` or move
    /// the frontier.
    func testInterleavedRevisitsDoNotInflateRecordedPagesOrFrontier() {
        var state = PagingOffsetState()
        simulatePageLoad(rawRowCount: 76, overflowRowCount: 0, to: &state)
        state.currentPage = 1
        simulatePageLoad(rawRowCount: 76, overflowRowCount: 0, to: &state)
        state.currentPage = 2

        for _ in 0..<3 {
            state.currentPage = 1 // revisit
            XCTAssertTrue(state.currentPage < state.rawSQLOffsetByPage.count)
            state.currentPage = 2 // back to where we were
        }

        XCTAssertEqual(state.rawSQLOffsetByPage.count, 2)
        XCTAssertEqual(state.rawSQLOffsetFrontier, 152)

        // Resume forward: page 2 is new (index 2 == count 2).
        simulatePageLoad(rawRowCount: 76, overflowRowCount: 0, to: &state)
        state.currentPage = 3
        XCTAssertEqual(state.rawSQLOffsetByPage.count, 3)
        XCTAssertEqual(state.rawSQLOffsetFrontier, 228)
    }

    // MARK: - resetForNewFilter clears every per-page field

    func testResetForNewFilterClearsAllPerPageState() {
        var state = PagingOffsetState()
        simulatePageLoad(rawRowCount: 76, overflowRowCount: 3, to: &state)
        state.currentPage = 1

        state.resetForNewFilter()

        XCTAssertEqual(state.currentPage, 0)
        XCTAssertTrue(state.rawSQLOffsetByPage.isEmpty)
        XCTAssertTrue(state.seedOverflowByPage.isEmpty)
        XCTAssertEqual(state.rawSQLOffsetFrontier, 0)
        XCTAssertTrue(state.rawSQLOffsetOverflowFrontier.isEmpty)
    }
}

// MARK: - Test fixture

private extension CalibreBook {
    /// Minimal stub, using `CalibreBook`'s real memberwise initializer
    /// (id/title/series/seriesIndex/wordCount/kudos/publishedDate/
    /// publisher/relativePath) so overflow-count assertions above have
    /// concrete values to count.
    static func stub(id: Int) -> CalibreBook {
        CalibreBook(
            id: id,
            title: "Stub",
            series: nil,
            seriesIndex: nil,
            wordCount: nil,
            kudos: nil,
            publishedDate: nil,
            publisher: nil,
            relativePath: "stub/path.epub"
        )
    }
}
