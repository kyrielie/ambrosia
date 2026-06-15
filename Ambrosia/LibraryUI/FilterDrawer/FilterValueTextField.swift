import SwiftUI

// MARK: - FilterValueTextField
//
// A TextField replacement used inside FilterRuleRow for fields that support
// live autocomplete suggestions (.tag, .authorName, .title).
//
// Design constraints:
//   • Suggestions are fetched off-actor via Task.detached so the SQLite read
//     never blocks the main thread.
//   • A minimum of 2 characters is required before any query fires, matching
//     the behaviour of the search-bar suggestion panel.
//   • The popover is dismissed as soon as the user selects a suggestion OR
//     clears the field below the threshold.  It does NOT auto-apply the filter.
//   • Fields that don't support autocomplete (.series, .comment, .fulltext, …)
//     render a plain TextField with no suggestion machinery at all — zero overhead.
//   • Task cancellation: a new fetch cancels the previous one via a stored
//     Task handle, preventing stale results from landing after the user has
//     already typed further.

struct FilterValueTextField: View {

    // MARK: Inputs

    let placeholder: String
    @Binding var text: String
    let field: FilterField
    /// Read-only access to Calibre for running suggestion queries.
    let library: CalibreLibrary?
    /// Called when the user taps a suggestion row. The caller writes the value
    /// back to its own binding; this view does not own the source of truth.
    let onSelect: (String) -> Void

    // MARK: State

    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    /// Cancellation handle for the in-flight fetch task.
    @State private var fetchTask: Task<Void, Never>? = nil

    // MARK: Constants

    private static let minimumQueryLength = 2
    private static let suggestionLimit    = 7

    // MARK: Body

    var body: some View {
        if supportsAutocomplete {
            autocompleteTextField
        } else {
            plainTextField
        }
    }

    // MARK: - Plain variant (no overhead for unsupported fields)

    private var plainTextField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Autocomplete variant

    private var autocompleteTextField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .onChange(of: text, initial: false) { _, newValue in
                schedulesFetch(for: newValue)
            }
            .popover(isPresented: $showSuggestions, arrowEdge: .bottom) {
                suggestionPopover
            }
    }

    // MARK: - Suggestion popover content

    private var suggestionPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, value in
                Button {
                    onSelect(value)
                    showSuggestions = false
                    suggestions = []
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: fieldIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .center)
                        Text(value)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(suggestionRowBackground)

                if index < suggestions.count - 1 {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .frame(width: 260)
        // Prevent the popover from being taller than ~10 rows
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Subtle hover-style background using the system material, keeps the
    /// popover visually consistent with SearchSuggestionsView.
    private var suggestionRowBackground: some View {
        Color(NSColor.controlBackgroundColor).opacity(0.001) // hit-testing only; .plain handles highlight
    }

    // MARK: - Fetch logic

    /// Whether this field benefits from DB-backed autocomplete.
    private var supportsAutocomplete: Bool {
        switch field {
        case .tag, .authorName, .title: return true
        default:                         return false
        }
    }

    private var fieldIcon: String {
        switch field {
        case .tag:        return "tag"
        case .authorName: return "person"
        case .title:      return "book"
        default:          return "magnifyingglass"
        }
    }

    /// Cancel any in-flight fetch and schedule a new one, or clear the list
    /// immediately when the query falls below the minimum length.
    private func schedulesFetch(for query: String) {
        fetchTask?.cancel()
        fetchTask = nil

        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard trimmed.count >= Self.minimumQueryLength, let library else {
            // Below threshold — collapse the popover without animation so it
            // doesn't flicker as the user types the first character.
            if showSuggestions {
                showSuggestions = false
                suggestions = []
            }
            return
        }

        // Capture immutable values so the detached task is Sendable-clean.
        let capturedField   = field
        let capturedLimit   = Self.suggestionLimit

        fetchTask = Task.detached(priority: .userInitiated) {
            // Bail early if cancelled before we even start the query.
            guard !Task.isCancelled else { return }

            let results: [String]
            switch capturedField {
            case .tag:
                results = library.tagSuggestions(prefix: trimmed, limit: capturedLimit)
            case .authorName:
                results = library.authorSuggestions(prefix: trimmed, limit: capturedLimit)
            case .title:
                results = library.titleSuggestions(prefix: trimmed, limit: capturedLimit)
            default:
                results = []
            }

            // Check cancellation again after the (blocking) DB call returns.
            guard !Task.isCancelled else { return }

            await MainActor.run {
                suggestions      = results
                showSuggestions  = !results.isEmpty
            }
        }
    }
}
