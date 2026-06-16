import Foundation

// MARK: - SearchActivityLog
//
// Lightweight in-memory ring buffer holding the most recent search and filter
// operations performed in the current library session.
//
// Design rationale:
//   • Searches are transient UI state — logging to ambrosia_meta.db would require
//     schema additions and async writes on the hot path.
//   • 200 entries covering the current session is sufficient for the Activity view.
//   • The log is cleared on library switch (LibrarySession calls clear()).
//   • Thread-safety: all mutations happen on the main actor via the append() method
//     which callers invoke from @MainActor contexts (toolbar, content views).

@MainActor
final class SearchActivityLog {

    static let shared = SearchActivityLog()

    private init() {}

    private(set) var entries: [SearchActivityEntry] = []
    private let capacity = 200

    // MARK: - Write

    /// Record a committed search/filter operation.
    /// Called after the result count is known (i.e. after loadPage returns).
    ///
    /// - Parameters:
    ///   - searchText:        The raw search field text. Pass "" if none.
    ///   - filterExpression:  The active FilterExpression. Pass nil or empty if none.
    ///   - resultCount:       Number of results shown to the user.
    func append(
        searchText: String,
        filterExpression: FilterExpression?,
        resultCount: Int
    ) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExpr = filterExpression?.hasCompleteRules == true

        // Don't log a no-op (empty search, no filter).
        guard !trimmed.isEmpty || hasExpr else { return }

        // Deduplicate: skip if identical to most recent entry.
        if let last = entries.last,
           last.searchText == trimmed,
           last.filterExpression?.hasCompleteRules == hasExpr,
           last.resultCount == resultCount { return }

        let entry = SearchActivityEntry(
            id: UUID(),
            date: Date(),
            searchText: trimmed,
            filterExpression: hasExpr ? filterExpression : nil,
            resultCount: resultCount
        )

        if entries.count >= capacity { entries.removeFirst() }
        entries.append(entry)
    }

    // MARK: - Read

    /// Returns entries newest-first, ready for display in the activity feed.
    func recentEntries(limit: Int = 200) -> [SearchActivityEntry] {
        Array(entries.suffix(limit).reversed())
    }

    // MARK: - Lifecycle

    /// Call on library switch to discard stale session data.
    func clear() {
        entries.removeAll()
    }
}
