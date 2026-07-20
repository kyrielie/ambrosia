import Foundation

/// Paging-offset bookkeeping for one view's current scroll position through
/// a filtered result set. Owned per-view, not shared — List and Email can be
/// scrolled to different pages of the same filter at the same time (their
/// rawSQLOffset bookkeeping is stateful and diverges independently under
/// series-grouping overflow), so this struct is passed around by the owning
/// view rather than stored inside LibraryQueryController itself.
struct PagingOffsetState {
    var currentPage: Int = 0

    /// Raw SQL row offset for the current page. When grouping is on,
    /// visibility filtering strips most rows, so `currentPage * pageSize`
    /// drifts far behind the actual SQL position. This tracks the true SQL
    /// offset independently.
    var rawSQLOffset: Int = 0

    /// Stack of prior rawSQLOffset values, one push per forward page, so
    /// "Previous" can pop back to the exact offset instead of guessing
    /// currentPage * pageSize.
    var rawSQLOffsetHistory: [Int] = []

    /// Overflow from the group-aware drain loop in loadPage: the loop stops
    /// once it has >= pageSize visible rows, which can overshoot by up to
    /// pageFetchLimit - 1. The excess is buffered here and prepended to the
    /// next forward page instead of being re-fetched (rawSQLOffset has
    /// already moved past it) or silently dropped.
    var rawSQLOffsetOverflow: [CalibreBook] = []

    /// What kind of loadPage() call this is, with respect to
    /// rawSQLOffset/rawSQLOffsetHistory bookkeeping. The grouped drain
    /// branch in loadPage() used to push/advance this state unconditionally
    /// on every call, including calls triggered by "← Previous" itself and
    /// by unrelated reloads (filter reapply, membershipVersion bumps during
    /// background AO3 extraction). That double-mutated the history stack:
    /// Previous would pop a value and then the resulting reload would push
    /// a fresh (already-stale) one right back, so backward paging past the
    /// end of a drained/grouped search replayed the same exhausted offset
    /// forever instead of rewinding. See incident notes below.
    ///
    /// - forward: Next, or the first-ever load of a page (including page 0
    ///   after a filter/sort reset). Pushes the pre-drain offset onto
    ///   history, then advances rawSQLOffset to the post-drain offset.
    /// - backward: Previous. rawSQLOffsetHistory has already been popped by
    ///   the button action before currentPage changed; loadPage() re-drains
    ///   from the restored rawSQLOffset but must NOT push again.
    /// - reload: same page, different cause. Re-drains from the current
    ///   (unchanged) rawSQLOffset and must not touch history at all.
    ///
    /// Set explicitly at every call site that changes `currentPage` or
    /// otherwise triggers loadPage(); loadPage() consumes it and resets it
    /// to `.reload` so a stray follow-up call defaults to the safe,
    /// non-mutating case rather than silently inheriting `.forward`.
    enum NavigationIntent {
        case forward
        case backward
        case reload
    }

    mutating func resetForNewFilter() {
        currentPage = 0
        rawSQLOffset = 0
        rawSQLOffsetHistory = []
        rawSQLOffsetOverflow = []
    }
}

// MARK: - Incident notes: backward-pagination offset corruption
//
// Symptom: paging backward ("← Previous") through a search whose results
// required the group-aware drain loop (shouldGroupSeriesRows == true, i.e.
// visibility filtering stripped enough rows that a single SQL page window
// collapsed to fewer than pageSize visible rows) would, after reaching the
// true end of the result set, show empty pages on every subsequent Previous
// click instead of the expected earlier rows.
//
// Root cause: rawSQLOffsetHistory.append(rawSQLOffset) plus the
// rawSQLOffset = <post-drain offset> assignment ran unconditionally inside
// loadPage()'s grouped drain branch, on every call through that branch —
// not just forward navigation. Clicking Previous popped a history entry and
// set rawSQLOffset to it, then currentPage -= 1 fired .onChange(of:
// currentPage), which called loadPage() again; that call re-entered the
// same drain branch and re-pushed/re-advanced rawSQLOffset from whatever it
// had just been set to, corrupting the entry the next Previous click needed.
// A background reload (e.g. an AO3 extraction batch bumping
// membershipVersion) hitting the same branch had the identical effect even
// with no page navigation at all.
//
// Fix: `PagingOffsetState.NavigationIntent`, set explicitly by every call
// site that triggers loadPage(), consumed once per call. Only `.forward`
// pushes to rawSQLOffsetHistory; `.backward` and `.reload` re-run the drain
// loop to repopulate the current page's rows but never mutate the history
// stack. See loadPage()'s grouped branch in LibraryRootView.swift.


/// Filtering logic shared by `LibraryRootView` and `EmailLibraryViewController`.
///
/// §Phase2 (partial): this extracts the lowest-risk, genuinely pure pieces of
/// the ~17 near-identical methods duplicated across the two views —
/// `currentVisibilityPolicy` construction, `visibleIDs`, `visibleBooks`, and
/// `intersect`. Both views now call through this one implementation instead
/// of keeping their own copies.
///
/// `applyFilterRules()` and `loadPage()` are NOT moved here in this pass —
/// they are the two largest, most state-coupled methods (SwiftUI `@State`
/// paging offsets on the List side, `NSViewController` instance state on the
/// Email side), and mechanically relocating ~300+ line functions with that
/// much surrounding paging/offset bookkeeping in one sitting is exactly the
/// kind of single large change the source plan (ambrosia_caching_plan.md /
/// the Finding 2 discussion) warns against attempting all at once. Both
/// views' `loadPage()` already call into the cached `CalibreLibrary` methods
/// with `visibilityVersion:` wired in (§Phase3), which is what actually
/// fixes the "switching views re-fetches everything" problem; moving the
/// surrounding orchestration into this controller is a follow-up refactor,
/// not a prerequisite for that fix.
///
/// One instance is owned per view (`LibraryRootView` holds one,
/// `EmailLibraryViewController` holds one). This type intentionally holds no
/// paging-offset state itself — List and Email can be scrolled to different
/// pages of the same filtered result at the same time, so offset state stays
/// owned by each view and is passed in as needed by whatever still calls into
/// `CalibreLibrary` directly.
///
/// Deliberately NOT `@MainActor`: it holds no mutable state and calls no
/// actor-isolated APIs (`LibraryVisibilityPolicy` is a plain value type), so
/// leaving it unisolated avoids actor-isolation friction where it's stored as
/// a plain `let` property on `LibraryRootView` (a SwiftUI `View` struct).
final class LibraryQueryController {

    /// "list" or "email" — used only for `LibraryFilterDebug` log labels, so
    /// existing manual-repro log-reading workflows keep working unchanged.
    let surfaceLabel: String

    init(surfaceLabel: String) {
        self.surfaceLabel = surfaceLabel
    }

    /// Builds the visibility policy from the current toggle state and the
    /// four ID sets that drive it. Callers pass their own (session-mirrored,
    /// see LibrarySession.refreshCollectionSnapshots) `@State`/instance
    /// copies of `skippedIDs`/`seriesOrMergedIDs`/`ao3PublisherIDs`/
    /// `anthologyIDs` — this method does not read `LibrarySession` directly,
    /// so it stays usable from a plain view-model context without needing a
    /// `LibrarySession` reference.
    func visibilityPolicy(
        showSkippedCollection: Bool,
        shouldGroupSeriesRows: Bool,
        hideNonAO3PublisherBooks: Bool,
        hideAnthologyBooks: Bool,
        hideDuplicateBooks: Bool,
        skippedIDs: Set<Int>,
        seriesOrMergedIDs: Set<Int>,
        ao3PublisherIDs: Set<Int>,
        anthologyIDs: Set<Int>,
        duplicateLoserIDs: Set<Int>
    ) -> LibraryVisibilityPolicy {
        LibraryVisibilityPolicy(
            showSkippedCollection: showSkippedCollection,
            shouldGroupSeriesRows: shouldGroupSeriesRows,
            hideNonAO3PublisherBooks: hideNonAO3PublisherBooks,
            hideAnthologyBooks: hideAnthologyBooks,
            hideDuplicateBooks: hideDuplicateBooks,
            skippedIDs: skippedIDs,
            seriesOrMergedIDs: seriesOrMergedIDs,
            ao3PublisherIDs: ao3PublisherIDs,
            anthologyIDs: anthologyIDs,
            duplicateLoserIDs: duplicateLoserIDs
        )
    }

    func visibleIDs(_ ids: [Int], policy: LibraryVisibilityPolicy) -> [Int] {
        policy.filter(ids)
    }

    func intersect(_ ids: [Int], with optionalIDs: [Int]?) -> [Int] {
        LibraryQueryHelpers.intersect(ids, with: optionalIDs)
    }

    /// Filters raw (unfiltered-by-visibility) hydrated books down to what
    /// should actually be shown. Ports the `#if DEBUG` breakdown diagnostic
    /// that previously existed only in `LibraryRootView`'s copy of this
    /// method (`EmailLibraryViewController`'s copy was missing it) so both
    /// surfaces get the same debug visibility going forward.
    func visibleBooks(_ raw: [CalibreBook], policy: LibraryVisibilityPolicy) -> [CalibreBook] {
        #if DEBUG
        if policy.shouldGroupSeriesRows && !raw.isEmpty {
            let strippedBySkipped = raw.filter { !policy.showSkippedCollection && policy.skippedIDs.contains($0.id) }.count
            let strippedBySeriesOrMerged = raw.filter { policy.seriesOrMergedIDs.contains($0.id) }.count
            let strippedByPublisher = raw.filter { policy.hideNonAO3PublisherBooks && !$0.isAO3PublisherBook }.count
            let strippedByAnthology = raw.filter { policy.hideAnthologyBooks && $0.isDescriptionAnthology }.count
            let strippedByDuplicate = raw.filter { policy.hideDuplicateBooks && policy.duplicateLoserIDs.contains($0.id) }.count
            LibraryFilterDebug.log("visibleBooks.breakdown", [
                "surface": surfaceLabel,
                "raw": raw.count,
                "seriesOrMergedIDsSize": policy.seriesOrMergedIDs.count,
                "strippedBySkipped": strippedBySkipped,
                "strippedBySeriesOrMerged": strippedBySeriesOrMerged,
                "strippedByPublisher": strippedByPublisher,
                "strippedByAnthology": strippedByAnthology,
                "strippedByDuplicate": strippedByDuplicate,
                "sampleStrippedIDs": raw.filter { policy.seriesOrMergedIDs.contains($0.id) }.prefix(5).map(\.id).map(String.init).joined(separator: ",")
            ])
        }
        #endif
        return policy.filter(raw)
    }
}
