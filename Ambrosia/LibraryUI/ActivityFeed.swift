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
struct SearchActivityEntry: Identifiable, Sendable {
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
    var displaySummary: String {
        var parts: [String] = []
        if !searchText.isEmpty { parts.append("\u{201C}\(searchText)\u{201D}") }
        if let expr = filterExpression, expr.hasCompleteRules {
            let rules = expr.groups.flatMap(\.completeRules)
            let ruleDesc = rules.prefix(2).map { "\($0.field.label): \($0.value)" }.joined(separator: ", ")
            parts.append(rules.count > 2 ? "\(ruleDesc) +\(rules.count - 2) more" : ruleDesc)
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
        case .session(let e, _):           return "s-\(e.id)"
        case .annotation(let a, _, _):     return "a-\(a.id.uuidString)"
        case .collectionChange(let c, _):  return "c-\(c.id)"
        case .search(let s):               return "q-\(s.id.uuidString)"
        }
    }

    // MARK: Common accessors

    var date: Date {
        switch self {
        case .session(let e, _):           return e.sessionStart
        case .annotation(let a, _, _):     return a.createdDate
        case .collectionChange(let c, _):  return c.addedAt
        case .search(let s):               return s.date
        }
    }

    /// Non-nil only for book-linked entries.
    var book: CalibreBook? {
        switch self {
        case .session(_, let b):           return b
        case .annotation(_, _, let b):     return b
        case .collectionChange(_, let b):  return b
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
