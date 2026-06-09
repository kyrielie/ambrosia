import SwiftUI

// MARK: - SuggestionKind

enum SuggestionKind {
    case tag, author, title, series

    var icon: String {
        switch self {
        case .tag:    return "tag"
        case .author: return "person"
        case .title:  return "book"
        case .series: return "books.vertical"
        }
    }

    var label: String {
        switch self {
        case .tag:    return "Tag"
        case .author: return "Author"
        case .title:  return "Title"
        case .series: return "Series"
        }
    }

    var prefixString: String {
        switch self {
        case .tag:    return "tag:"
        case .author: return "author:"
        case .title:  return "title:"
        case .series: return "series:"
        }
    }

    /// The FilterField this suggestion kind maps to when committed.
    var filterField: FilterField {
        switch self {
        case .tag:    return .tag      // may be overridden to .rating by asFilterRule
        case .author: return .authorName
        case .title:  return .title
        case .series: return .series
        }
    }

    /// The FilterOperator to use when creating a rule from this suggestion.
    /// Tags are classified through AO3TagKind so rating tags default to .ratingAtMost.
    func filterOperator(for value: String) -> FilterOperator {
        switch self {
        case .tag:
            // AO3 rating tags get ratingAtMost as the default — "show me books
            // rated at most X" is almost always what the user wants when they
            // pick a rating from suggestions.
            if case .rating = AO3TagKind.classify(value) { return .ratingAtMost }
            return .equals
        case .author:
            return .equals
        case .title, .series:
            return .contains
        }
    }
}

// MARK: - SearchSuggestion

struct SearchSuggestion: Identifiable {
    let id    = UUID()
    let kind:  SuggestionKind
    let value: String

    /// The FilterRule this suggestion produces when committed.
    var asFilterRule: FilterRule {
        let op    = kind.filterOperator(for: value)
        // AO3TagKind drives the field for rating/warning/category tags
        let field: FilterField
        switch kind {
        case .tag:
            field = AO3TagKind.classify(value).filterField
        default:
            field = kind.filterField
        }
        return FilterRule(field: field, op: op, value: value)
    }
}

// MARK: - SuggestionRowView

/// Individual row with macOS-native hover highlight.
private struct SuggestionRowView: View {
    let suggestion: SearchSuggestion
    let onSelect:   (SearchSuggestion) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(suggestion)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: suggestion.kind.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)
                Text(suggestion.value)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15)
                                  : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}


// MARK: - SuggestionSection

struct SuggestionSection: Identifiable {
    let id          = UUID()
    let kind:        SuggestionKind
    let suggestions: [SearchSuggestion]
}

// MARK: - SearchSuggestionsView

/// Sectioned suggestion list rendered inside a non-activating NSPanel.
/// Carries its own .regularMaterial background so the panel window can be
/// fully transparent — the same approach used by Spotlight and Xcode Quick Open.
struct SearchSuggestionsView: View {
    let sections:  [SuggestionSection]
    let onSelect:  (SearchSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                if !section.suggestions.isEmpty {
                    sectionHeader(section.kind)
                    ForEach(Array(section.suggestions.enumerated()), id: \.element.id) { idx, suggestion in
                        suggestionRow(suggestion)
                        if idx < section.suggestions.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 280, maxWidth: 400)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func sectionHeader(_ kind: SuggestionKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(kind.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("adds filter")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func suggestionRow(_ suggestion: SearchSuggestion) -> some View {
        SuggestionRowView(suggestion: suggestion, onSelect: onSelect)
    }
}

// MARK: - Suggestion computation

/// Computes sectioned suggestions for the current raw search text.
/// Detects whether a prefix is active and narrows accordingly.
func computeSectionedSuggestions(for searchText: String,
                                  library: CalibreLibrary) -> [SuggestionSection] {
    let text = searchText.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return [] }

    // author: prefix → author completions only
    if let prefix = text.activePrefixValue(for: "author:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = library.authorSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .author, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .author, suggestions: suggestions)]
    }

    // series: prefix → series completions only
    if let prefix = text.activePrefixValue(for: "series:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = library.seriesSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .series, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .series, suggestions: suggestions)]
    }

    // title: prefix → title completions only
    if let prefix = text.activePrefixValue(for: "title:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = library.titleSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .title, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .title, suggestions: suggestions)]
    }

    // tag: prefix → tag completions only
    if let prefix = text.activePrefixValue(for: "tag:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = library.tagSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .tag, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .tag, suggestions: suggestions)]
    }

    // Plain text (≥ 2 chars) → multi-section: titles, authors, tags, series
    guard text.count >= 2 else { return [] }

    let titleSugs  = library.titleSuggestions(prefix: text, limit: 3)
        .map { SearchSuggestion(kind: .title,  value: $0) }
    let authorSugs = library.authorSuggestions(prefix: text, limit: 3)
        .map { SearchSuggestion(kind: .author, value: $0) }
    let tagSugs    = library.tagSuggestions(prefix: text, limit: 4)
        .map { SearchSuggestion(kind: .tag,    value: $0) }
    let seriesSugs = library.seriesSuggestions(prefix: text, limit: 3)
        .map { SearchSuggestion(kind: .series, value: $0) }

    return [
        SuggestionSection(kind: .title,  suggestions: titleSugs),
        SuggestionSection(kind: .author, suggestions: authorSugs),
        SuggestionSection(kind: .tag,    suggestions: tagSugs),
        SuggestionSection(kind: .series, suggestions: seriesSugs),
    ].filter { !$0.suggestions.isEmpty }
}
