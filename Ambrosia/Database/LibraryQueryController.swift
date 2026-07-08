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

    mutating func resetForNewFilter() {
        currentPage = 0
        rawSQLOffset = 0
        rawSQLOffsetHistory = []
        rawSQLOffsetOverflow = []
    }
}


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
        skippedIDs: Set<Int>,
        seriesOrMergedIDs: Set<Int>,
        ao3PublisherIDs: Set<Int>,
        anthologyIDs: Set<Int>
    ) -> LibraryVisibilityPolicy {
        LibraryVisibilityPolicy(
            showSkippedCollection: showSkippedCollection,
            shouldGroupSeriesRows: shouldGroupSeriesRows,
            hideNonAO3PublisherBooks: hideNonAO3PublisherBooks,
            hideAnthologyBooks: hideAnthologyBooks,
            skippedIDs: skippedIDs,
            seriesOrMergedIDs: seriesOrMergedIDs,
            ao3PublisherIDs: ao3PublisherIDs,
            anthologyIDs: anthologyIDs
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
            LibraryFilterDebug.log("visibleBooks.breakdown", [
                "surface": surfaceLabel,
                "raw": raw.count,
                "seriesOrMergedIDsSize": policy.seriesOrMergedIDs.count,
                "strippedBySkipped": strippedBySkipped,
                "strippedBySeriesOrMerged": strippedBySeriesOrMerged,
                "strippedByPublisher": strippedByPublisher,
                "strippedByAnthology": strippedByAnthology,
                "sampleStrippedIDs": raw.filter { policy.seriesOrMergedIDs.contains($0.id) }.prefix(5).map(\.id).map(String.init).joined(separator: ",")
            ])
        }
        #endif
        return policy.filter(raw)
    }
}
