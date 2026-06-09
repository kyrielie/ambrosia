import SwiftUI

// MARK: - SuggestionKind

enum SuggestionKind {
    case tag, author, title

    var icon: String {
        switch self {
        case .tag:    return "tag"
        case .author: return "person"
        case .title:  return "book"
        }
    }
}

// MARK: - SearchSuggestion

struct SearchSuggestion: Identifiable {
    let id = UUID()
    let kind: SuggestionKind
    let value: String   // the raw tag/author/title name

    var displayText: String { value }

    /// Text inserted into the search field when this suggestion is selected.
    /// Tags insert as plain text; authors/titles use their prefix and quote the value.
    var insertText: String {
        switch kind {
        case .tag:    return value
        case .author: return "author:\"\(value)\""
        case .title:  return "title:\"\(value)\""
        }
    }
}

// MARK: - SearchSuggestionsView

/// Floating suggestion list shown below the search field.
/// Presented via a SwiftUI overlay (ZStack), not NSPopover.
struct SearchSuggestionsView: View {
    let suggestions: [SearchSuggestion]
    let onSelect: (SearchSuggestion) -> Void

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestion.kind.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(suggestion.displayText)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                    if suggestion.id != suggestions.last?.id {
                        Divider()
                    }
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 8)
            .frame(maxWidth: 380)
        }
    }
}

// MARK: - Suggestion update logic (mixed into BookGridItem / LibraryToolbarState callers)

/// Computes the appropriate suggestions for the current search text.
/// Called on a 150 ms debounce — faster than the 300 ms page-load debounce.
func computeSuggestions(for searchText: String, library: CalibreLibrary) -> [SearchSuggestion] {
    let q = searchText

    // author: prefix active → show author completions
    if let prefix = q.activePrefixValue(for: "author:"), !prefix.isEmpty {
        return library.authorSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .author, value: $0) }
    }

    // title: prefix active → show title completions
    if let prefix = q.activePrefixValue(for: "title:"), !prefix.isEmpty {
        return library.titleSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .title, value: $0) }
    }

    // Plain text → show tag suggestions for the last typed word (≥2 chars)
    let lastWord = q.components(separatedBy: .whitespaces).last ?? ""
    if lastWord.count >= 2, !lastWord.contains(":") {
        return library.tagSuggestions(prefix: lastWord)
            .map { SearchSuggestion(kind: .tag, value: $0) }
    }

    return []
}

/// Applies a selected suggestion to the current search text.
/// Replaces the triggering fragment (last word or prefix+value) with `suggestion.insertText`.
func applyingSuggestion(_ suggestion: SearchSuggestion, to searchText: String) -> String {
    switch suggestion.kind {
    case .tag:
        // Replace the last plain word
        var words = searchText.components(separatedBy: .whitespaces)
        if !words.isEmpty { words[words.count - 1] = suggestion.insertText }
        return words.joined(separator: " ")

    case .author:
        // Replace "author:<typed>" with the full insertText
        if let range = searchText.range(of: "author:", options: [.backwards, .caseInsensitive]) {
            let before = String(searchText[searchText.startIndex..<range.lowerBound])
            return (before + suggestion.insertText).trimmingCharacters(in: .whitespaces)
        }
        return searchText + suggestion.insertText

    case .title:
        // Replace "title:<typed>" with the full insertText
        if let range = searchText.range(of: "title:", options: [.backwards, .caseInsensitive]) {
            let before = String(searchText[searchText.startIndex..<range.lowerBound])
            return (before + suggestion.insertText).trimmingCharacters(in: .whitespaces)
        }
        return searchText + suggestion.insertText
    }
}
