import AppKit
import Observation

// MARK: - View mode

/// The three display modes for the library window.
/// D3 (ranking view) is defined here so LibraryViewController can compile the full switch now.
enum LibraryViewMode: Int {
    case list    = 0
    case email   = 1
    case ranking = 2
}

// MARK: - LibraryToolbarState

/// Single source of truth for all state that crosses the toolbar/content boundary.
///
/// Created once by LibraryViewController, injected into:
///   - The SwiftUI environment so LibraryRootView observes it directly.
///   - LibraryWindowController so the NSToolbar delegate can mutate it.
///   - EmailLibraryViewController (and future RankingLibraryViewController) so they
///     respond to toolbar changes with no extra wiring.
///
/// Filter state also lives here (not in individual views) so all three view modes
/// share the same filter result when the user switches modes mid-session.
@Observable
final class LibraryToolbarState {

    // MARK: - Toolbar-driven fields

    var searchText:       String          = ""
    var sortField:        SortField       = .title
    var ascending:        Bool            = true
    var viewMode:         LibraryViewMode = .list

    // Trigger flags — views observe these and act, then set back to false.
    var showFilterDrawer:     Bool = false
    var showCollections:      Bool = false
    var showReadingGoal:      Bool = false
    var triggerExport:        Bool = false
    var toggleEmailSidebar:   Bool = false

    // MARK: - Filter state (shared across all view modes)

    var filterExpression:  FilterExpression = FilterExpression()
    var activeFilterResult: FilterResult?   = nil

    // MARK: - Convenience

    var hasActiveFilter: Bool { activeFilterResult != nil }
}
