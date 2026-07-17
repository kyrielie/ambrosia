import Foundation

/// Consolidates the library's visibility/exclusion rules into one value type.
///
/// Before this, each new "hide X" toggle (skipped, series-or-merged
/// collapsing, AO3-publisher-only, anthology-hiding) was a bool + cached
/// `Set<Int>` pair, independently wired through `LibraryQueryHelpers.visibleIDs`/
/// `.visibleBooks`, `CalibreLibrary.randomSortedPage`/`wordCountSortedPage`
/// (`restrictIDs`/`excludeIDs`), and duplicated across `LibraryRootView` and
/// `EmailLibraryViewController` — 16 wiring sites for two toggles.
///
/// A future toggle (e.g. "General Audiences only") is a one-field addition to
/// this struct, not a new parameter threaded through half a dozen signatures.
///
/// This is a pure value type: no actor isolation, no shared mutable state,
/// trivially testable and safe to construct fresh per query.
struct LibraryVisibilityPolicy {
    var showSkippedCollection: Bool
    var shouldGroupSeriesRows: Bool
    var hideNonAO3PublisherBooks: Bool
    var hideAnthologyBooks: Bool
    var hideDuplicateBooks: Bool

    var skippedIDs: Set<Int>
    var seriesOrMergedIDs: Set<Int>
    var ao3PublisherIDs: Set<Int>
    var anthologyIDs: Set<Int>
    var duplicateLoserIDs: Set<Int>

    static let allowAll = LibraryVisibilityPolicy(
        showSkippedCollection: true,
        shouldGroupSeriesRows: false,
        hideNonAO3PublisherBooks: false,
        hideAnthologyBooks: false,
        hideDuplicateBooks: false,
        skippedIDs: [],
        seriesOrMergedIDs: [],
        ao3PublisherIDs: [],
        anthologyIDs: [],
        duplicateLoserIDs: []
    )

    /// True if `id` should be shown under these rules.
    ///
    /// `ao3PublisherIDs` is an allow-list (must be a member when the toggle is
    /// on); the other four sets are deny-lists (must NOT be a member).
    /// `duplicateLoserIDs` holds the non-winning calibre IDs of any AO3-work
    /// duplicate group (see `DuplicateBookDetector`) — never books without
    /// extracted AO3 metadata, which can't be identified as duplicates.
    func isVisible(_ id: Int) -> Bool {
        (showSkippedCollection || !skippedIDs.contains(id)) &&
        (!shouldGroupSeriesRows || !seriesOrMergedIDs.contains(id)) &&
        (!hideNonAO3PublisherBooks || ao3PublisherIDs.contains(id)) &&
        (!hideAnthologyBooks || !anthologyIDs.contains(id)) &&
        (!hideDuplicateBooks || !duplicateLoserIDs.contains(id))
    }

    /// Same rule set, evaluated against a hydrated `CalibreBook` instead of a
    /// bare ID. Used where the book is already fetched (e.g. the sql-paged
    /// list path) and per-book properties (`isAO3PublisherBook`,
    /// `isDescriptionAnthology`) are cheaper/more current than the cached ID
    /// sets — the two are kept in sync by construction (`AnthologyDetector`
    /// backs both `anthologyIDs`'s Swift-side check and
    /// `CalibreBook.isDescriptionAnthology`), so either form gives the same
    /// answer for a given book.
    func isVisible(_ book: CalibreBook) -> Bool {
        (showSkippedCollection || !skippedIDs.contains(book.id)) &&
        (!shouldGroupSeriesRows || !seriesOrMergedIDs.contains(book.id)) &&
        (!hideNonAO3PublisherBooks || book.isAO3PublisherBook) &&
        (!hideAnthologyBooks || !book.isDescriptionAnthology) &&
        (!hideDuplicateBooks || !duplicateLoserIDs.contains(book.id))
    }

    func filter(_ ids: [Int]) -> [Int] {
        ids.filter(isVisible)
    }

    func filter(_ books: [CalibreBook]) -> [CalibreBook] {
        books.filter(isVisible)
    }
}
