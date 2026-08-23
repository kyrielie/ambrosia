import Foundation

// MARK: - Filter

/// The filter tabs shown at the top of the Activity view.
enum ActivityFeedFilter: String, CaseIterable, Identifiable {
    case all         = "All"
    case sessions    = "Sessions"
    case annotations = "Annotations"
    case collections = "Collections"
    case searches    = "Searches"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .all:         return "clock"
        case .sessions:    return "book"
        case .annotations: return "highlighter"
        case .collections: return "folder"
        case .searches:    return "magnifyingglass"
        }
    }

    var emptyStateSymbol: String {
        switch self {
        case .all:         return "clock"
        case .sessions:    return "book.closed"
        case .annotations: return "highlighter"
        case .collections: return "folder.badge.questionmark"
        case .searches:    return "magnifyingglass"
        }
    }

    var emptyStateMessage: String {
        switch self {
        case .all:
            return "Open a work, make highlights, add books to collections, or run a search to see activity here."
        case .sessions:
            return "Open a work in the reader to start logging reading sessions."
        case .annotations:
            return "Highlight text or add bookmarks in the reader to see them here."
        case .collections:
            return "Add books to collections to see those events here."
        case .searches:
            return "Run a search or apply filters to see them here."
        }
    }
}

// MARK: - Search / filter activity entry

/// A logged search-text query or filter-expression operation.
/// `filterExpression` is non-nil when filter rules were applied.
/// `searchText` is non-empty when a free-text query was committed.
/// Both may be present simultaneously.
struct SearchActivityEntry: Identifiable, Sendable, Codable {
    let id: UUID
    let date: Date
    /// The raw search text that was committed (may be empty).
    let searchText: String
    /// The filter expression that was applied (nil if filter was empty).
    let filterExpression: FilterExpression?
    /// Number of results returned at the time of the query.
    let resultCount: Int

    // MARK: Display helpers

    /// Short human-readable summary for the row subject line.
    ///
    /// Filter portion delegates to `FilterSummary.humanReadable`, which is
    /// group-aware (preserves AND-within-group / OR-between-group structure),
    /// rather than flattening every group's rules into one undifferentiated
    /// list — a plain `groups.flatMap(\.completeRules)` here would silently
    /// drop which rules were ANDed vs ORed.
    var displaySummary: String {
        var parts: [String] = []
        if !searchText.isEmpty { parts.append("\u{201C}\(searchText)\u{201D}") }
        if let expr = filterExpression, expr.hasCompleteRules {
            parts.append(FilterSummary.humanReadable(expression: expr))
        }
        return parts.joined(separator: " · ")
    }

    var hasFilterRules: Bool {
        filterExpression?.hasCompleteRules == true
    }
}

// MARK: - Feed entry

/// A single item in the unified activity feed.
/// Each case wraps the typed payload plus the resolved `CalibreBook` where applicable.
enum ActivityFeedEntry: Identifiable {
    case session(ReadingHistoryEntry, book: CalibreBook)
    case annotation(Annotation, calibreID: Int, book: CalibreBook)
    case collectionChange(CollectionActivityEntry, book: CalibreBook)
    case search(SearchActivityEntry)

    // MARK: Identifiable

    var id: String {
        switch self {
        case .session(let entry, _):       return "s-\(entry.id)"
        case .annotation(let annotation, _, _): return "a-\(annotation.id.uuidString)"
        case .collectionChange(let change, _): return "c-\(change.id)"
        case .search(let searchEntry):     return "q-\(searchEntry.id.uuidString)"
        }
    }

    // MARK: Common accessors

    var date: Date {
        switch self {
        case .session(let entry, _):       return entry.sessionStart
        case .annotation(let annotation, _, _): return annotation.createdDate
        case .collectionChange(let change, _): return change.addedAt
        case .search(let searchEntry):     return searchEntry.date
        }
    }

    /// Non-nil only for book-linked entries.
    var book: CalibreBook? {
        switch self {
        case .session(_, let book):        return book
        case .annotation(_, _, let book):  return book
        case .collectionChange(_, let book): return book
        case .search:                      return nil
        }
    }

    // MARK: Filter membership

    var matchesFilter: ActivityFeedFilter {
        switch self {
        case .session:           return .sessions
        case .annotation:        return .annotations
        case .collectionChange:  return .collections
        case .search:            return .searches
        }
    }
}
