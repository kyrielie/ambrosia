import Foundation

// MARK: - SearchQuery

/// Structured result of parsing a free-form search string.
///
/// Supported syntax:
///   tag:action              → books whose tag list contains "action"
///   author:rowling          → books whose author name contains "rowling"
///   title:goblet            → books whose title contains "goblet"
///   tag:action author:jo    → AND logic: both conditions must match
///   goblet fire             → plain fuzzy title/author search (unchanged)
///   tag:action goblet       → tag filter AND plain fuzzy on "goblet"
///
/// Prefix tokens stack additively and combine with any active FilterDrawer rules.
struct SearchQuery {
    let tagTerms:    [String]   // each produces a SQL EXISTS subquery on tags
    let authorTerms: [String]   // each produces a SQL EXISTS subquery on authors
    let titleTerms:  [String]   // each produces LOWER(b.title) LIKE ?
    let plainTerms:  [String]   // remainder → fuzzyTitleCondition per term

    /// IDs matched by full-text search (I3). When non-nil, plain-text search
    /// is resolved to an explicit ID set; plainTerms are ignored by SQL path.
    var ftsMatchedIDs: [Int]? = nil

    var isEmpty: Bool {
        tagTerms.isEmpty && authorTerms.isEmpty &&
        titleTerms.isEmpty && plainTerms.isEmpty &&
        (ftsMatchedIDs == nil || ftsMatchedIDs!.isEmpty)
    }
}

// MARK: - SearchQueryParser

struct SearchQueryParser {

    /// Parse a raw search string into a `SearchQuery`.
    static func parse(_ input: String) -> SearchQuery {
        var tags: [String]    = []
        var authors: [String] = []
        var titles: [String]  = []
        var plain: [String]   = []

        let tokens = tokenise(input)
        for token in tokens {
            if let value = token.droppingPrefix("tag:"),    !value.isEmpty { tags.append(value) }
            else if let value = token.droppingPrefix("author:"), !value.isEmpty { authors.append(value) }
            else if let value = token.droppingPrefix("title:"),  !value.isEmpty { titles.append(value) }
            else if !token.isEmpty { plain.append(token) }
        }
        return SearchQuery(tagTerms: tags, authorTerms: authors,
                           titleTerms: titles, plainTerms: plain)
    }

    /// Splits on whitespace, honouring double-quoted phrases.
    private static func tokenise(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for ch in input {
            if ch == "\"" { inQuote.toggle() }
            else if ch == " " && !inQuote {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

// MARK: - String helper

private extension String {
    /// Returns the string with `prefix` removed, or nil if the string doesn't start with it.
    func droppingPrefix(_ prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

// MARK: - activePrefixValue helper (used by autocomplete in I2)

extension String {
    /// Returns the value after the last occurrence of `prefix` in the string,
    /// or nil if that prefix is not present.
    /// e.g. "tag:action author:ro".activePrefixValue(for: "author:") → "ro"
    func activePrefixValue(for prefix: String) -> String? {
        let lower = lowercased()
        let lowerPrefix = prefix.lowercased()
        guard let range = lower.range(of: lowerPrefix, options: .backwards) else { return nil }
        let after = String(self[range.upperBound...])
        // Stop at the next whitespace — the value is only the immediately-following token.
        let value = after.components(separatedBy: .whitespaces).first ?? after
        return value
    }
}
