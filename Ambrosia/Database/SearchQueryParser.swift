import Foundation

// MARK: - SearchQuery

/// Structured result of parsing a free-form search string.
///
/// Supported prefix syntax:
///   tag:<value>      → filter by tag (whole remainder is the value)
///   author:<value>   → filter by author
///   title:<value>    → filter by title
///   series:<value>   → filter by series
///   status:<value>   → filter by AO3 completion status
///   fulltext:<value> → search EPUB body text
///   <plain text>     → fuzzy title search
///
/// Only ONE prefix token is expected per search string. When the user commits
/// a token (Return or suggestion tap), it is immediately translated into a
/// FilterRule and the search field is cleared. The parser is also used to
/// detect the active prefix while the user is still typing, to drive suggestions.
struct SearchQuery {
    let tagTerms:    [String]
    let authorTerms: [String]
    let titleTerms:  [String]
    let seriesTerms: [String]
    let statusTerms: [String]
    let fulltextPhrase: String?
    let plainTerms:  [String]

    /// IDs matched by full-text search. When non-nil, plainTerms are replaced
    /// by this explicit ID set in the SQL layer.
    var ftsMatchedIDs: [Int]? = nil

    var isEmpty: Bool {
        tagTerms.isEmpty && authorTerms.isEmpty &&
        titleTerms.isEmpty && seriesTerms.isEmpty &&
        statusTerms.isEmpty &&
        (fulltextPhrase == nil || fulltextPhrase!.isEmpty) &&
        plainTerms.isEmpty &&
        (ftsMatchedIDs == nil || ftsMatchedIDs!.isEmpty)
    }

    // MARK: - Scoped token detection

    /// If the entire search string is a single scoped prefix token, returns the
    /// corresponding FilterRule. Used by the commit path to convert "tag:horror"
    /// into a FilterRule without leaving residual plain terms.
    var asSingleFilterRule: FilterRule? {
        // Exactly one scoped term and no plain text
        if tagTerms.count == 1 && authorTerms.isEmpty && titleTerms.isEmpty
            && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty {
            let v = AO3TagSearchResolver.canonicalTerm(for: tagTerms[0])
            // AO3 rating/warning/category tags get their proper field and operator.
            // Rating tags default to .ratingAtMost — almost always the right intent.
            let kind = AO3TagKind.classify(v)
            let field = kind.filterField
            let op: FilterOperator
            switch kind {
            case .rating: op = .ratingAtMost
            default:      op = .equals
            }
            return FilterRule(field: field, op: op, value: v)
        }
        if authorTerms.count == 1 && tagTerms.isEmpty && titleTerms.isEmpty
            && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty {
            return FilterRule(field: .authorName, op: .equals, value: authorTerms[0])
        }
        if titleTerms.count == 1 && tagTerms.isEmpty && authorTerms.isEmpty
            && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty {
            return FilterRule(field: .title, op: .contains, value: titleTerms[0])
        }
        if seriesTerms.count == 1 && tagTerms.isEmpty && authorTerms.isEmpty
            && titleTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty {
            return FilterRule(field: .series, op: .contains, value: seriesTerms[0])
        }
        if statusTerms.count == 1 && tagTerms.isEmpty && authorTerms.isEmpty
            && titleTerms.isEmpty && seriesTerms.isEmpty && plainTerms.isEmpty,
           let status = AO3CompletionStatus(userValue: statusTerms[0]) {
            return FilterRule(field: .status, op: .equals, value: status.rawValue)
        }
        if let fulltextPhrase, !fulltextPhrase.isEmpty, tagTerms.isEmpty && authorTerms.isEmpty
            && titleTerms.isEmpty && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty {
            return FilterRule(field: .fulltext, op: .contains, value: fulltextPhrase)
        }
        return nil
    }

    // Convenience init without seriesTerms
    init(tagTerms: [String], authorTerms: [String], titleTerms: [String],
         plainTerms: [String], ftsMatchedIDs: [Int]? = nil) {
        self.tagTerms      = tagTerms
        self.authorTerms   = authorTerms
        self.titleTerms    = titleTerms
        self.seriesTerms   = []
        self.statusTerms   = []
        self.fulltextPhrase = nil
        self.plainTerms    = plainTerms
        self.ftsMatchedIDs = ftsMatchedIDs
    }

    init(tagTerms: [String], authorTerms: [String], titleTerms: [String],
         seriesTerms: [String], plainTerms: [String], ftsMatchedIDs: [Int]? = nil) {
        self.tagTerms      = tagTerms
        self.authorTerms   = authorTerms
        self.titleTerms    = titleTerms
        self.seriesTerms   = seriesTerms
        self.statusTerms   = []
        self.fulltextPhrase = nil
        self.plainTerms    = plainTerms
        self.ftsMatchedIDs = ftsMatchedIDs
    }

    init(tagTerms: [String], authorTerms: [String], titleTerms: [String],
         seriesTerms: [String], statusTerms: [String], fulltextPhrase: String? = nil,
         plainTerms: [String], ftsMatchedIDs: [Int]? = nil) {
        self.tagTerms      = tagTerms
        self.authorTerms   = authorTerms
        self.titleTerms    = titleTerms
        self.seriesTerms   = seriesTerms
        self.statusTerms   = statusTerms
        self.fulltextPhrase = fulltextPhrase
        self.plainTerms    = plainTerms
        self.ftsMatchedIDs = ftsMatchedIDs
    }
}

// MARK: - SearchQueryParser

struct SearchQueryParser {

    /// Parse a raw search string into a `SearchQuery`.
    ///
    /// Tag, author, title, series values consume EVERYTHING after the colon —
    /// spaces included — so "tag:Middle School" becomes tagTerms: ["Middle School"].
    /// This matches the commit behaviour where the whole field content after the
    /// prefix is the value.
    static func parse(_ input: String) -> SearchQuery {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Check for a leading prefix that consumes the rest of the string.
        // Order matters: check longest prefixes first.
        let prefixes: [(String, (String) -> SearchQuery)] = [
            ("author:", { v in SearchQuery(tagTerms: [], authorTerms: [v], titleTerms: [], seriesTerms: [], plainTerms: []) }),
            ("series:", { v in SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [v], plainTerms: []) }),
            ("status:", { v in SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], statusTerms: [v], plainTerms: []) }),
            ("fulltext:", { v in SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], statusTerms: [], fulltextPhrase: v, plainTerms: []) }),
            ("title:",  { v in SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [v], seriesTerms: [], plainTerms: []) }),
            ("tag:",    { v in SearchQuery(tagTerms: [v], authorTerms: [], titleTerms: [], seriesTerms: [], plainTerms: []) }),
        ]

        for (prefix, builder) in prefixes {
            if trimmed.lowercased().hasPrefix(prefix) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    return builder(value)
                }
            }
        }

        // No prefix — treat entire string as plain search terms
        let words = trimmed
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [],
                           seriesTerms: [], plainTerms: words)
    }
}

// MARK: - activePrefixValue helper (used by autocomplete suggestion computation)

extension String {
    /// Returns the typed value after the last occurrence of a known prefix, or nil.
    /// e.g. "tag:Middle Sc" → activePrefixValue(for: "tag:") → "Middle Sc"
    func activePrefixValue(for prefix: String) -> String? {
        let lower = lowercased()
        guard lower.hasPrefix(prefix.lowercased()) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
