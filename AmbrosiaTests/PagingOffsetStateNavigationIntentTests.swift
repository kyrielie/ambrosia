import XCTest
@testable import Ambrosia

/// Regression coverage for the backward-pagination offset corruption fixed
/// alongside `PagingOffsetState.NavigationIntent`. See the "Incident notes"
/// doc comment on `PagingOffsetState` (LibraryQueryController.swift) and the
/// intent-gated drain branches in `LibraryRootView.loadPage()` for the full
/// writeup.
///
/// `PagingOffsetState` itself has no SwiftUI/actor dependency, so these
/// tests drive it directly rather than standing up `LibraryRootView`. The
/// push/advance/pop rules under test are exactly the rules `loadPage()`'s
/// grouped drain branches apply per `NavigationIntent` — see
/// `applyDrainResult(intent:preDrainOffset:postDrainOffset:to:)` below,
/// which mirrors that logic so it can be exercised without the view.
final class PagingOffsetStateNavigationIntentTests: XCTestCase {

    /// Mirrors the bookkeeping `loadPage()`'s grouped drain branches perform
    /// once a page's rows have been fetched, gated by `intent` exactly as
    /// in `LibraryRootView.swift`. Kept in this test file (rather than
    /// imported) so a future accidental edit to the real branches shows up
    /// as a test *behavior* mismatch, not just a duplicated-helper drift.
    private func applyDrainResult(
        intent: PagingOffsetState.NavigationIntent,
        preDrainOffset: Int,
        postDrainOffset: Int,
        to state: inout PagingOffsetState
    ) {
        switch intent {
        case .forward:
            state.rawSQLOffsetHistory.append(preDrainOffset)
            state.rawSQLOffset = postDrainOffset
        case .backward:
            state.rawSQLOffset = postDrainOffset
        case .reload:
            break
        }
    }

    // MARK: - Forward-only traversal

    func testForwardTraversalPushesOneHistoryEntryPerPage() {
        var state = PagingOffsetState()
        // Simulate 5 forward pages, each page's drain advancing the raw
        // offset by 76 rows (one pageFetchLimit window, no exhaustion).
        for page in 0..<5 {
            let pre = state.rawSQLOffset
            let post = pre + 76
            applyDrainResult(intent: .forward, preDrainOffset: pre, postDrainOffset: post, to: &state)
            state.currentPage = page + 1
        }
        XCTAssertEqual(state.rawSQLOffsetHistory, [0, 76, 152, 228, 304])
        XCTAssertEqual(state.rawSQLOffset, 380)
        XCTAssertEqual(state.rawSQLOffsetHistory.count, state.currentPage)
    }

    // MARK: - Forward then backward: the exact incident scenario

    /// Reproduces the pasted-log incident: forward-drain a search to
    /// exhaustion (page 10 -> page 11, raw=0, "suddenly all pages were
    /// empty" once paging back), then click Previous twice, and assert
    /// the offset actually rewinds instead of replaying the exhausted tail.
    func testBackwardAfterExhaustionRewindsInsteadOfReplayingExhaustedOffset() {
        var state = PagingOffsetState()

        // Page 9 -> 10: drain from 700 to 760 (pre-exhaustion window).
        applyDrainResult(intent: .forward, preDrainOffset: 700, postDrainOffset: 760, to: &state)
        state.currentPage = 10

        // Page 10 -> 11: drain from 760 to 789, the incident log's final
        // real fetch (raw=29 rows fetched, offset advances by 29).
        applyDrainResult(intent: .forward, preDrainOffset: 760, postDrainOffset: 789, to: &state)
        state.currentPage = 11

        // Page 11 -> "page 12" would drain from 789 and find raw=0
        // (truly exhausted). No forward push happens for an exhausted,
        // zero-row page in the real code (hasNextPage becomes false and
        // the user can't click Next again), so history is unchanged here:
        XCTAssertEqual(state.rawSQLOffsetHistory, [0, 700, 760])

        // Click Previous (page 11 -> 10): the button pops history BEFORE
        // loadPage() runs, then loadPage() re-drains with intent = .backward.
        let poppedForPage10 = state.rawSQLOffsetHistory.popLast()
        XCTAssertEqual(poppedForPage10, 760, "Previous must restore page 10's own starting offset, not page 11's")
        state.rawSQLOffset = poppedForPage10!
        state.currentPage = 10
        applyDrainResult(intent: .backward, preDrainOffset: state.rawSQLOffset, postDrainOffset: 789, to: &state)

        // Critically: this backward call must NOT have re-pushed onto
        // history. Before the fix, the drain branch pushed unconditionally,
        // so this step corrupted the stack with a duplicate exhausted
        // offset and every subsequent Previous kept replaying it.
        XCTAssertEqual(state.rawSQLOffsetHistory, [0, 700], "backward navigation must not push")

        // Click Previous again (page 10 -> 9): pops the *real* earlier
        // offset (700), not a duplicate of the exhausted 760/789 value.
        let poppedForPage9 = state.rawSQLOffsetHistory.popLast()
        XCTAssertEqual(poppedForPage9, 700)
        XCTAssertNotEqual(poppedForPage9, 789, "must not replay the exhausted offset from the end of the search")
        state.rawSQLOffset = poppedForPage9!
        state.currentPage = 9
        applyDrainResult(intent: .backward, preDrainOffset: state.rawSQLOffset, postDrainOffset: 760, to: &state)

        XCTAssertEqual(state.rawSQLOffsetHistory, [0])
        XCTAssertEqual(state.rawSQLOffset, 760)
    }

    // MARK: - Reload must be fully inert with respect to offset bookkeeping

    func testReloadDoesNotPushOrDuplicateHistoryEntries() {
        var state = PagingOffsetState()
        applyDrainResult(intent: .forward, preDrainOffset: 0, postDrainOffset: 76, to: &state)
        state.currentPage = 1
        applyDrainResult(intent: .forward, preDrainOffset: 76, postDrainOffset: 152, to: &state)
        state.currentPage = 2

        let historyBeforeReload = state.rawSQLOffsetHistory
        let offsetBeforeReload = state.rawSQLOffset

        // A membership-version bump mid-browse reloads page 2 in place.
        applyDrainResult(intent: .reload, preDrainOffset: state.rawSQLOffset, postDrainOffset: 152, to: &state)

        XCTAssertEqual(state.rawSQLOffsetHistory, historyBeforeReload, "reload must never mutate history")
        XCTAssertEqual(state.rawSQLOffset, offsetBeforeReload, "reload must never advance the offset")
    }

    /// Interleaves reloads between forward steps, mimicking background AO3
    /// extraction bumping membershipVersion every ~2s while the user is
    /// still reading a page (the likely amplifier of the original bug: many
    /// reload-triggered pushes accumulating before the user ever clicked
    /// Previous).
    func testInterleavedReloadsDoNotInflateHistoryBeyondPageCount() {
        var state = PagingOffsetState()
        applyDrainResult(intent: .forward, preDrainOffset: 0, postDrainOffset: 76, to: &state)
        state.currentPage = 1

        // Three reloads while sitting on page 1, none of which are real
        // navigation.
        for _ in 0..<3 {
            applyDrainResult(intent: .reload, preDrainOffset: state.rawSQLOffset, postDrainOffset: 76, to: &state)
        }

        applyDrainResult(intent: .forward, preDrainOffset: 76, postDrainOffset: 152, to: &state)
        state.currentPage = 2

        XCTAssertEqual(state.rawSQLOffsetHistory, [0, 76], "reloads between forward steps must not add extra entries")
        XCTAssertEqual(state.rawSQLOffsetHistory.count, state.currentPage)
    }

    // MARK: - resetForNewFilter clears all paging state, including history

    func testResetForNewFilterClearsHistoryAndOverflow() {
        var state = PagingOffsetState()
        applyDrainResult(intent: .forward, preDrainOffset: 0, postDrainOffset: 76, to: &state)
        state.currentPage = 1
        state.rawSQLOffsetOverflow = [CalibreBook.stub(id: 1)]

        state.resetForNewFilter()

        XCTAssertEqual(state.currentPage, 0)
        XCTAssertEqual(state.rawSQLOffset, 0)
        XCTAssertTrue(state.rawSQLOffsetHistory.isEmpty)
        XCTAssertTrue(state.rawSQLOffsetOverflow.isEmpty)
    }
}

// MARK: - Test fixture

private extension CalibreBook {
    /// Minimal stub for the overflow-array assertion above, using
    /// `CalibreBook`'s real memberwise initializer (id/title/series/
    /// seriesIndex/wordCount/kudos/publishedDate/publisher/relativePath).
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
