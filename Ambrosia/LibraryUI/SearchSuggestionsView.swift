import SwiftUI

// MARK: - SuggestionKind

enum SuggestionKind {
    case tag, author, title, series, status, fulltext

    var icon: String {
        switch self {
        case .tag:    return "tag"
        case .author: return "person"
        case .title:  return "book"
        case .series: return "books.vertical"
        case .status: return "checkmark.circle"
        case .fulltext: return "doc.text.magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .tag:    return "Tag"
        case .author: return "Author"
        case .title:  return "Title"
        case .series: return "Series"
        case .status: return "Status"
        case .fulltext: return "Full Text"
        }
    }

    var prefixString: String {
        switch self {
        case .tag:    return "tag:"
        case .author: return "author:"
        case .title:  return "title:"
        case .series: return "series:"
        case .status: return "status:"
        case .fulltext: return "fulltext:"
        }
    }

    /// The FilterField this suggestion kind maps to when committed.
    var filterField: FilterField {
        switch self {
        case .tag:    return .tag      // may be overridden to .rating by asFilterRule
        case .author: return .authorName
        case .title:  return .title
        case .series: return .series
        case .status: return .status
        case .fulltext: return .fulltext
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
        case .author, .status:
            return .equals
        case .title, .series, .fulltext:
            return .contains
        }
    }
}

enum FilterRuleFactory {
    static func rule(for suggestion: SearchSuggestion) -> FilterRule {
        rule(kind: suggestion.kind, value: suggestion.value)
    }

    /// Async variant for tag suggestions: resolves the canonical term via
    /// `AmbrosiaMetaDB` (Invariant 10) before building the rule.
    static func rule(for suggestion: SearchSuggestion, metaDB: AmbrosiaMetaDB?) async -> FilterRule {
        if suggestion.kind == .tag, let metaDB {
            let resolved = await metaDB.canonicalTerm(for: suggestion.value)
            return rule(kind: .tag, value: suggestion.value, resolvedTagValue: resolved)
        }
        return rule(kind: suggestion.kind, value: suggestion.value)
    }

    static func tagPillRule(label: String, field: FilterField) -> FilterRule {
        if field == .tag {
            return rule(kind: .tag, value: label)
        }
        let op: FilterOperator = field == .rating ? .ratingAtMost : .equals
        return FilterRule(field: field, op: op, value: label)
    }

    private static func rule(kind: SuggestionKind, value: String, resolvedTagValue: String? = nil) -> FilterRule {
        let resolvedValue: String
        switch kind {
        case .tag:
            // Canonical term resolution is done asynchronously by the caller via
            // AmbrosiaMetaDB.canonicalTerm (Invariant 10). Use the pre-resolved
            // value when provided; fall back to the raw value when seeds are off
            // or metaDB is unavailable.
            resolvedValue = resolvedTagValue ?? value
        case .status:
            resolvedValue = AO3CompletionStatus(userValue: value)?.rawValue ?? value
        default:
            resolvedValue = value
        }

        let op = kind.filterOperator(for: resolvedValue)
        let field: FilterField
        switch kind {
        case .tag:
            field = AO3TagKind.classify(resolvedValue).filterField
        case .status:
            field = .status
        case .fulltext:
            field = .fulltext
        default:
            field = kind.filterField
        }
        return FilterRule(field: field, op: op, value: resolvedValue)
    }
}

// MARK: - SearchSuggestion

struct SearchSuggestion: Identifiable {
    let id    = UUID()
    let kind:  SuggestionKind
    let value: String

    /// The FilterRule this suggestion produces when committed.
    var asFilterRule: FilterRule {
        FilterRuleFactory.rule(for: self)
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
    let showsTrailingPrefixWarning: Bool
    let onSelect:  (SearchSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTrailingPrefixWarning {
                trailingPrefixWarningBanner
            }
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

    private var trailingPrefixWarningBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Only the first prefix is used; the rest is treated as plain text.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
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
            Text(kind == .fulltext ? "searches body" : "adds filter")
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
                                  library: CalibreLibrary) async -> [SuggestionSection] {
    let text = searchText.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return [] }

    // author: prefix → author completions only
    if let prefix = text.activePrefixValue(for: "author:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = await library.authorSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .author, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .author, suggestions: suggestions)]
    }

    // series: prefix → series completions only
    if let prefix = text.activePrefixValue(for: "series:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = await library.seriesSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .series, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .series, suggestions: suggestions)]
    }

    // title: prefix → title completions only
    if let prefix = text.activePrefixValue(for: "title:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = await library.titleSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .title, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .title, suggestions: suggestions)]
    }

    // tag: prefix → tag completions only
    if let prefix = text.activePrefixValue(for: "tag:") {
        guard !prefix.isEmpty else { return [] }
        let suggestions = await library.tagSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .tag, value: $0) }
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .tag, suggestions: suggestions)]
    }

    // status: prefix → fixed AO3 completion statuses only
    if let prefix = text.activePrefixValue(for: "status:") {
        let suggestions = statusSuggestions(prefix: prefix)
        return suggestions.isEmpty ? [] : [SuggestionSection(kind: .status, suggestions: suggestions)]
    }

    // fulltext: prefix is accepted as-is and intentionally has no completions.
    if text.activePrefixValue(for: "fulltext:") != nil {
        return []
    }

    // Plain text (≥ 2 chars) → multi-section: titles, authors, tags, series
    guard text.count >= 2 else { return [] }

    let titleSugs  = await library.titleSuggestions(prefix: text, limit: 3)
        .map { SearchSuggestion(kind: .title,  value: $0) }
    let authorSugs = await library.authorSuggestions(prefix: text, limit: 3)
        .map { SearchSuggestion(kind: .author, value: $0) }
    let tagSugs    = await library.tagSuggestions(prefix: text, limit: 4)
        .map { SearchSuggestion(kind: .tag,    value: $0) }
    let seriesSugs = await library.seriesSuggestions(prefix: text, limit: 3)
        .map { SearchSuggestion(kind: .series, value: $0) }
    let statusSugs = statusSuggestions(prefix: text)
    let fulltextSugs = [SearchSuggestion(kind: .fulltext, value: text)]

    return [
        SuggestionSection(kind: .fulltext, suggestions: fulltextSugs),
        SuggestionSection(kind: .title,  suggestions: titleSugs),
        SuggestionSection(kind: .author, suggestions: authorSugs),
        SuggestionSection(kind: .tag,    suggestions: tagSugs),
        SuggestionSection(kind: .series, suggestions: seriesSugs),
        SuggestionSection(kind: .status, suggestions: statusSugs),
    ].filter { !$0.suggestions.isEmpty }
}

private func statusSuggestions(prefix: String) -> [SearchSuggestion] {
    let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else {
        return AO3CompletionStatus.allCases.map { SearchSuggestion(kind: .status, value: $0.rawValue) }
    }
    return AO3CompletionStatus.allCases
        .filter { status in
            let value = status.rawValue.lowercased()
            return value.hasPrefix(needle)
        }
        .map { SearchSuggestion(kind: .status, value: $0.rawValue) }
}
