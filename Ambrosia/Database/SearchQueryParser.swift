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
    let tagTerms: [String]
    let authorTerms: [String]
    let titleTerms: [String]
    let seriesTerms: [String]
    let statusTerms: [String]
    let fulltextPhrase: String?
    let plainTerms: [String]

    var scopedTagTerms: [SearchTerm] = []
    var scopedAuthorTerms: [SearchTerm] = []
    var scopedTitleTerms: [SearchTerm] = []
    var scopedSeriesTerms: [SearchTerm] = []
    var semanticPhrase: String?

    var excludedTagTerms: [String] = []
    var excludedAuthorTerms: [String] = []
    var excludedTitleTerms: [String] = []
    var excludedSeriesTerms: [String] = []
    var wordCountGT: Int?
    var wordCountLT: Int?

    /// IDs matched by full-text search. When non-nil, plainTerms are replaced
    /// by this explicit ID set in the SQL layer.
    var ftsMatchedIDs: [Int]?

    /// Pre-resolved synonym expansions for each tag term, populated asynchronously
    /// by the caller via `AmbrosiaMetaDB.expandedTerms(for:)` before any SQL is built.
    /// When nil for a given term, `whereClause` falls back to the raw term.
    var expandedTagTerms: [String: [String]] = [:]

    /// True when a single scoped-prefix token's value contains a second known
    /// prefix token (e.g. "tag:horror author:smith"). Only one prefix is parsed
    /// per search string — the rest becomes part of the first prefix's literal
    /// value — so this flags the case where that's probably not what the user
    /// intended, without changing parsing behavior (see Phase 5 of the gap
    /// closure plan; multi-token parsing is explicitly out of scope here).
    var hasTrailingPrefixWarning: Bool = false

    var isEmpty: Bool {
        tagTerms.isEmpty && authorTerms.isEmpty &&
            titleTerms.isEmpty && seriesTerms.isEmpty &&
            statusTerms.isEmpty &&
            (fulltextPhrase?.isEmpty ?? true) &&
            (semanticPhrase?.isEmpty ?? true) &&
            plainTerms.isEmpty &&
            (ftsMatchedIDs?.isEmpty ?? true) &&
            excludedTagTerms.isEmpty && excludedAuthorTerms.isEmpty &&
            excludedTitleTerms.isEmpty && excludedSeriesTerms.isEmpty &&
            wordCountGT == nil && wordCountLT == nil
    }

    // MARK: - Scoped token detection

    /// If the entire search string is a single scoped prefix token, returns the
    /// corresponding FilterRule. Used by the commit path to convert "tag:horror"
    /// into a FilterRule without leaving residual plain terms.
    ///
    /// `resolvedTagTerm` is the canonical form of `tagTerms[0]` after synonym
    /// resolution, provided by the async caller via `AmbrosiaMetaDB.canonicalTerm`.
    /// When nil (seeds disabled or metaDB unavailable), the raw tag term is used.
    func asSingleFilterRule(resolvedTagTerm: String? = nil) -> FilterRule? {
        // Exactly one scoped term and no plain text
        if tagTerms.count == 1 && authorTerms.isEmpty && titleTerms.isEmpty
            && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty && (semanticPhrase?.isEmpty ?? true) {
            let term = scopedTagTerms.first ?? SearchTerm.parse(prefixValue: tagTerms[0])
            let resolvedTag = resolvedTagTerm ?? term.value
            // AO3 rating/warning/category tags get their proper field and operator.
            // Rating tags default to .ratingAtMost — almost always the right intent.
            let kind = AO3TagKind.classify(resolvedTag)
            let field = kind.filterField
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains:
                switch kind {
                case .rating: op = .ratingAtMost
                default:      op = .equals
                }
            }
            return FilterRule(field: field, op: op, value: resolvedTag)
        }
        if authorTerms.count == 1 && tagTerms.isEmpty && titleTerms.isEmpty
            && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty && (semanticPhrase?.isEmpty ?? true) {
            let term = scopedAuthorTerms.first ?? SearchTerm.parse(prefixValue: authorTerms[0])
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .equals
            }
            return FilterRule(field: .authorName, op: op, value: term.value)
        }
        if titleTerms.count == 1 && tagTerms.isEmpty && authorTerms.isEmpty
            && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty && (semanticPhrase?.isEmpty ?? true) {
            let term = scopedTitleTerms.first ?? SearchTerm.parse(prefixValue: titleTerms[0])
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .contains
            }
            return FilterRule(field: .title, op: op, value: term.value)
        }
        if seriesTerms.count == 1 && tagTerms.isEmpty && authorTerms.isEmpty
            && titleTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty && (semanticPhrase?.isEmpty ?? true) {
            let term = scopedSeriesTerms.first ?? SearchTerm.parse(prefixValue: seriesTerms[0])
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .contains
            }
            return FilterRule(field: .series, op: op, value: term.value)
        }
        if statusTerms.count == 1 && tagTerms.isEmpty && authorTerms.isEmpty
            && titleTerms.isEmpty && seriesTerms.isEmpty && plainTerms.isEmpty && (semanticPhrase?.isEmpty ?? true),
           let status = AO3CompletionStatus(userValue: statusTerms[0]) {
            return FilterRule(field: .status, op: .equals, value: status.rawValue)
        }
        if let fulltextPhrase, !fulltextPhrase.isEmpty, tagTerms.isEmpty && authorTerms.isEmpty
            && titleTerms.isEmpty && seriesTerms.isEmpty && statusTerms.isEmpty && plainTerms.isEmpty && (semanticPhrase?.isEmpty ?? true) {
            return FilterRule(field: .fulltext, op: .contains, value: fulltextPhrase)
        }
        return nil
    }

    /// Converts all scoped terms in this query into an array of `FilterRule`s.
    /// Tags are canonicalized via `canonicalTagResolver` if provided.
    func asFilterRules(canonicalTagResolver: ((String) async -> String)? = nil) async -> [FilterRule] {
        var rules: [FilterRule] = []

        for (index, tag) in tagTerms.enumerated() {
            let resolved: String
            if let resolver = canonicalTagResolver {
                resolved = await resolver(tag)
            } else {
                resolved = tag
            }
            let term = scopedTagTerms.indices.contains(index) ? scopedTagTerms[index] : SearchTerm.parse(prefixValue: tag)
            let kind = AO3TagKind.classify(resolved)
            let field = kind.filterField
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains:
                switch kind {
                case .rating: op = .ratingAtMost
                default:      op = .equals
                }
            }
            rules.append(FilterRule(field: field, op: op, value: resolved))
        }

        for (index, author) in authorTerms.enumerated() {
            let term = scopedAuthorTerms.indices.contains(index) ? scopedAuthorTerms[index] : SearchTerm.parse(prefixValue: author)
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .equals
            }
            rules.append(FilterRule(field: .authorName, op: op, value: term.value))
        }

        for (index, title) in titleTerms.enumerated() {
            let term = scopedTitleTerms.indices.contains(index) ? scopedTitleTerms[index] : SearchTerm.parse(prefixValue: title)
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .contains
            }
            rules.append(FilterRule(field: .title, op: op, value: term.value))
        }

        for (index, series) in seriesTerms.enumerated() {
            let term = scopedSeriesTerms.indices.contains(index) ? scopedSeriesTerms[index] : SearchTerm.parse(prefixValue: series)
            let op: FilterOperator
            switch term.mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .contains
            }
            rules.append(FilterRule(field: .series, op: op, value: term.value))
        }

        for status in statusTerms {
            if let parsed = AO3CompletionStatus(userValue: status) {
                rules.append(FilterRule(field: .status, op: .equals, value: parsed.rawValue))
            }
        }

        if let fulltext = fulltextPhrase, !fulltext.isEmpty {
            rules.append(FilterRule(field: .fulltext, op: .contains, value: fulltext))
        }

        for tag in excludedTagTerms {
            let resolved: String
            if let resolver = canonicalTagResolver {
                resolved = await resolver(tag)
            } else {
                resolved = tag
            }
            let kind = AO3TagKind.classify(resolved)
            let field = kind.filterField
            rules.append(FilterRule(field: field, op: .notEquals, value: resolved))
        }

        for author in excludedAuthorTerms {
            rules.append(FilterRule(field: .authorName, op: .notEquals, value: author))
        }

        for title in excludedTitleTerms {
            rules.append(FilterRule(field: .title, op: .notContains, value: title))
        }

        for series in excludedSeriesTerms {
            rules.append(FilterRule(field: .series, op: .notContains, value: series))
        }

        if let gt = wordCountGT {
            rules.append(FilterRule(field: .wordCountGT, op: .equals, value: "\(gt)"))
        }

        if let lt = wordCountLT {
            rules.append(FilterRule(field: .wordCountLT, op: .equals, value: "\(lt)"))
        }

        return rules
    }

    // Convenience init without seriesTerms
    init(tagTerms: [String], authorTerms: [String], titleTerms: [String],
         plainTerms: [String], ftsMatchedIDs: [Int]? = nil,
         scopedTagTerms: [SearchTerm]? = nil, scopedAuthorTerms: [SearchTerm]? = nil,
         scopedTitleTerms: [SearchTerm]? = nil, scopedSeriesTerms: [SearchTerm]? = nil,
         semanticPhrase: String? = nil) {
        self.tagTerms      = tagTerms
        self.authorTerms   = authorTerms
        self.titleTerms    = titleTerms
        self.seriesTerms   = []
        self.statusTerms   = []
        self.fulltextPhrase = nil
        self.plainTerms    = plainTerms
        self.ftsMatchedIDs = ftsMatchedIDs
        self.scopedTagTerms = scopedTagTerms ?? tagTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedAuthorTerms = scopedAuthorTerms ?? authorTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedTitleTerms = scopedTitleTerms ?? titleTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedSeriesTerms = scopedSeriesTerms ?? []
        self.semanticPhrase = semanticPhrase
    }

    init(tagTerms: [String], authorTerms: [String], titleTerms: [String],
         seriesTerms: [String], plainTerms: [String], ftsMatchedIDs: [Int]? = nil,
         scopedTagTerms: [SearchTerm]? = nil, scopedAuthorTerms: [SearchTerm]? = nil,
         scopedTitleTerms: [SearchTerm]? = nil, scopedSeriesTerms: [SearchTerm]? = nil,
         semanticPhrase: String? = nil) {
        self.tagTerms      = tagTerms
        self.authorTerms   = authorTerms
        self.titleTerms    = titleTerms
        self.seriesTerms   = seriesTerms
        self.statusTerms   = []
        self.fulltextPhrase = nil
        self.plainTerms    = plainTerms
        self.ftsMatchedIDs = ftsMatchedIDs
        self.scopedTagTerms = scopedTagTerms ?? tagTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedAuthorTerms = scopedAuthorTerms ?? authorTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedTitleTerms = scopedTitleTerms ?? titleTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedSeriesTerms = scopedSeriesTerms ?? seriesTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.semanticPhrase = semanticPhrase
    }

    init(tagTerms: [String], authorTerms: [String], titleTerms: [String],
         seriesTerms: [String], statusTerms: [String], fulltextPhrase: String? = nil,
         plainTerms: [String], ftsMatchedIDs: [Int]? = nil,
         scopedTagTerms: [SearchTerm]? = nil, scopedAuthorTerms: [SearchTerm]? = nil,
         scopedTitleTerms: [SearchTerm]? = nil, scopedSeriesTerms: [SearchTerm]? = nil,
         semanticPhrase: String? = nil) {
        self.tagTerms      = tagTerms
        self.authorTerms   = authorTerms
        self.titleTerms    = titleTerms
        self.seriesTerms   = seriesTerms
        self.statusTerms   = statusTerms
        self.fulltextPhrase = fulltextPhrase
        self.plainTerms    = plainTerms
        self.ftsMatchedIDs = ftsMatchedIDs
        self.scopedTagTerms = scopedTagTerms ?? tagTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedAuthorTerms = scopedAuthorTerms ?? authorTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedTitleTerms = scopedTitleTerms ?? titleTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.scopedSeriesTerms = scopedSeriesTerms ?? seriesTerms.map { SearchTerm.parse(prefixValue: $0) }
        self.semanticPhrase = semanticPhrase
    }
}

// MARK: - SearchQueryParser

// TODO: Multi-token parsing (e.g. "tag:x author:y" -> two rules) is out of
// scope for the trailing-prefix warning added in the gap closure plan
// (Phase 5, ambrosia_gap_closure_plan.md). The warning only flags the
// situation; it does not change parsing behavior.
struct SearchQueryParser {

    /// Parse a raw search string into a `SearchQuery`.
    ///
    /// Tag, author, title, series values consume EVERYTHING after the colon —
    /// spaces included — so "tag:Middle School" becomes tagTerms: ["Middle School"].
    /// This matches the commit behaviour where the whole field content after the
    /// prefix is the value.
    static func parse(_ input: String) -> SearchQuery {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        func unquoted(_ val: String) -> String {
            var str = val.trimmingCharacters(in: .whitespaces)
            if str.hasPrefix("\"") && str.hasSuffix("\"") && str.count >= 2 {
                str = String(str.dropFirst().dropLast())
            }
            return str
        }

        // Check for a leading prefix that consumes the rest of the string.
        // Order matters: check longest prefixes first.
        let prefixes: [(String, (String) -> SearchQuery)] = [
            ("author:=", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .exact, value: clean)
                return SearchQuery(tagTerms: [], authorTerms: [clean], titleTerms: [], seriesTerms: [],
                                   plainTerms: [], scopedAuthorTerms: [term])
            }),
            ("author:~", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .regex, value: clean)
                return SearchQuery(tagTerms: [], authorTerms: [clean], titleTerms: [], seriesTerms: [],
                                   plainTerms: [], scopedAuthorTerms: [term])
            }),
            ("author:", { value in
                let term = SearchTerm.parse(prefixValue: value)
                return SearchQuery(tagTerms: [], authorTerms: [term.value], titleTerms: [], seriesTerms: [],
                                   plainTerms: [], scopedAuthorTerms: [term])
            }),
            ("series:=", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .exact, value: clean)
                return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [clean],
                                   plainTerms: [], scopedSeriesTerms: [term])
            }),
            ("series:~", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .regex, value: clean)
                return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [clean],
                                   plainTerms: [], scopedSeriesTerms: [term])
            }),
            ("series:", { value in
                let term = SearchTerm.parse(prefixValue: value)
                return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [term.value],
                                   plainTerms: [], scopedSeriesTerms: [term])
            }),
            ("status:", { value in SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], statusTerms: [value], plainTerms: []) }),
            ("fulltext:", { value in
                SearchQuery(
                    tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [],
                    statusTerms: [], fulltextPhrase: value, plainTerms: []
                )
            }),
            ("semantic:", { value in
                SearchQuery(
                    tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [],
                    statusTerms: [], plainTerms: [], semanticPhrase: value
                )
            }),
            ("title:=", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .exact, value: clean)
                return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [clean], seriesTerms: [],
                                   plainTerms: [], scopedTitleTerms: [term])
            }),
            ("title:~", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .regex, value: clean)
                return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [clean], seriesTerms: [],
                                   plainTerms: [], scopedTitleTerms: [term])
            }),
            ("title:", { value in
                let term = SearchTerm.parse(prefixValue: value)
                return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [term.value], seriesTerms: [],
                                   plainTerms: [], scopedTitleTerms: [term])
            }),
            ("tag:=", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .exact, value: clean)
                return SearchQuery(tagTerms: [clean], authorTerms: [], titleTerms: [], seriesTerms: [],
                                   plainTerms: [], scopedTagTerms: [term])
            }),
            ("tag:~", { value in
                let clean = unquoted(value)
                let term = SearchTerm(mode: .regex, value: clean)
                return SearchQuery(tagTerms: [clean], authorTerms: [], titleTerms: [], seriesTerms: [],
                                   plainTerms: [], scopedTagTerms: [term])
            }),
            ("tag:", { value in
                let term = SearchTerm.parse(prefixValue: value)
                return SearchQuery(tagTerms: [term.value], authorTerms: [], titleTerms: [], seriesTerms: [],
                                   plainTerms: [], scopedTagTerms: [term])
            })
        ]

        for (prefix, builder) in prefixes where trimmed.lowercased().hasPrefix(prefix) {
            let value = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                var query = builder(value)
                let lowerValue = value.lowercased()
                query.hasTrailingPrefixWarning = prefixes.contains { otherPrefix, _ in
                    otherPrefix != prefix && lowerValue.contains(otherPrefix)
                }
                return query
            }
        }

        // No prefix — treat entire string as plain search terms
        let words = trimmed
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [],
                           seriesTerms: [], plainTerms: words)
    }

    /// Parse multiple tokens (e.g. `author:Alice tag:"Slow Burn" title:Secret -tag:Angst words:>50k`)
    /// into structured scoped lists, numeric ranges, and remaining plain search words.
    static func parseMultiToken(_ input: String) -> SearchQuery {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], plainTerms: [])
        }

        var tags: [String] = []
        var authors: [String] = []
        var titles: [String] = []
        var series: [String] = []
        var scopedTags: [SearchTerm] = []
        var scopedAuthors: [SearchTerm] = []
        var scopedTitles: [SearchTerm] = []
        var scopedSeries: [SearchTerm] = []
        var statuses: [String] = []
        var fulltext: String?
        var semantic: String?
        var excludedTags: [String] = []
        var excludedAuthors: [String] = []
        var excludedTitles: [String] = []
        var excludedSeries: [String] = []
        var wordGT: Int?
        var wordLT: Int?
        var plain: [String] = []

        func unquoted(_ val: String) -> String {
            var str = val.trimmingCharacters(in: .whitespaces)
            if str.hasPrefix("\"") && str.hasSuffix("\"") && str.count >= 2 {
                str = String(str.dropFirst().dropLast())
            }
            return str
        }

        let tokens = tokenize(trimmed)
        let prefixMap: [(String, (String) -> Void)] = [
            ("-author:=", { val in excludedAuthors.append(unquoted(val)) }),
            ("-author:~", { val in excludedAuthors.append(unquoted(val)) }),
            ("-author:", { val in excludedAuthors.append(unquoted(val)) }),
            ("-series:=", { val in excludedSeries.append(unquoted(val)) }),
            ("-series:~", { val in excludedSeries.append(unquoted(val)) }),
            ("-series:", { val in excludedSeries.append(unquoted(val)) }),
            ("-title:=", { val in excludedTitles.append(unquoted(val)) }),
            ("-title:~", { val in excludedTitles.append(unquoted(val)) }),
            ("-title:", { val in excludedTitles.append(unquoted(val)) }),
            ("-tag:=", { val in excludedTags.append(unquoted(val)) }),
            ("-tag:~", { val in excludedTags.append(unquoted(val)) }),
            ("-tag:", { val in excludedTags.append(unquoted(val)) }),
            ("-warning:", { val in excludedTags.append(unquoted(val)) }),
            ("-category:", { val in excludedTags.append(unquoted(val)) }),
            ("author:=", { val in
                let clean = unquoted(val)
                authors.append(clean)
                scopedAuthors.append(SearchTerm(mode: .exact, value: clean))
            }),
            ("author:~", { val in
                let clean = unquoted(val)
                authors.append(clean)
                scopedAuthors.append(SearchTerm(mode: .regex, value: clean))
            }),
            ("author:", { val in
                let term = SearchTerm.parse(prefixValue: val)
                authors.append(term.value)
                scopedAuthors.append(term)
            }),
            ("series:=", { val in
                let clean = unquoted(val)
                series.append(clean)
                scopedSeries.append(SearchTerm(mode: .exact, value: clean))
            }),
            ("series:~", { val in
                let clean = unquoted(val)
                series.append(clean)
                scopedSeries.append(SearchTerm(mode: .regex, value: clean))
            }),
            ("series:", { val in
                let term = SearchTerm.parse(prefixValue: val)
                series.append(term.value)
                scopedSeries.append(term)
            }),
            ("status:", { statuses.append(unquoted($0)) }),
            ("fulltext:", { fulltext = unquoted($0) }),
            ("semantic:", { semantic = unquoted($0) }),
            ("title:=", { val in
                let clean = unquoted(val)
                titles.append(clean)
                scopedTitles.append(SearchTerm(mode: .exact, value: clean))
            }),
            ("title:~", { val in
                let clean = unquoted(val)
                titles.append(clean)
                scopedTitles.append(SearchTerm(mode: .regex, value: clean))
            }),
            ("title:", { val in
                let term = SearchTerm.parse(prefixValue: val)
                titles.append(term.value)
                scopedTitles.append(term)
            }),
            ("tag:=", { val in
                let clean = unquoted(val)
                tags.append(clean)
                scopedTags.append(SearchTerm(mode: .exact, value: clean))
            }),
            ("tag:~", { val in
                let clean = unquoted(val)
                tags.append(clean)
                scopedTags.append(SearchTerm(mode: .regex, value: clean))
            }),
            ("tag:", { val in
                let term = SearchTerm.parse(prefixValue: val)
                tags.append(term.value)
                scopedTags.append(term)
            }),
            ("warning:=", { val in
                let clean = unquoted(val)
                tags.append(clean)
                scopedTags.append(SearchTerm(mode: .exact, value: clean))
            }),
            ("warning:~", { val in
                let clean = unquoted(val)
                tags.append(clean)
                scopedTags.append(SearchTerm(mode: .regex, value: clean))
            }),
            ("warning:", { val in
                let term = SearchTerm.parse(prefixValue: val)
                tags.append(term.value)
                scopedTags.append(term)
            }),
            ("category:=", { val in
                let clean = unquoted(val)
                tags.append(clean)
                scopedTags.append(SearchTerm(mode: .exact, value: clean))
            }),
            ("category:~", { val in
                let clean = unquoted(val)
                tags.append(clean)
                scopedTags.append(SearchTerm(mode: .regex, value: clean))
            }),
            ("category:", { val in
                let term = SearchTerm.parse(prefixValue: val)
                tags.append(term.value)
                scopedTags.append(term)
            })
        ]

        for token in tokens {
            let lower = token.lowercased()

            // Check word count range syntax e.g. words:>50k, words:<20k, words:10k-50k
            if lower.hasPrefix("words:") {
                let rangeStr = String(token.dropFirst("words:".count)).trimmingCharacters(in: .whitespaces)
                if rangeStr.hasPrefix(">") {
                    wordGT = parseWordCount(String(rangeStr.dropFirst()))
                } else if rangeStr.hasPrefix("<") {
                    wordLT = parseWordCount(String(rangeStr.dropFirst()))
                } else if rangeStr.contains("-") {
                    let parts = rangeStr.split(separator: "-", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        wordGT = parseWordCount(parts[0])
                        wordLT = parseWordCount(parts[1])
                    }
                } else if let exact = parseWordCount(rangeStr) {
                    wordGT = exact
                }
                continue
            }

            var matched = false
            for (prefix, assign) in prefixMap where lower.hasPrefix(prefix) {
                let rawVal = String(token.dropFirst(prefix.count))
                let val = rawVal.hasPrefix("\"") ? rawVal : rawVal.trimmingCharacters(in: .whitespaces)
                if !val.isEmpty {
                    assign(val)
                    matched = true
                    break
                }
            }
            if !matched && !token.isEmpty {
                plain.append(unquoted(token))
            }
        }

        var query = SearchQuery(
            tagTerms: tags,
            authorTerms: authors,
            titleTerms: titles,
            seriesTerms: series,
            statusTerms: statuses,
            fulltextPhrase: fulltext,
            plainTerms: plain,
            scopedTagTerms: scopedTags,
            scopedAuthorTerms: scopedAuthors,
            scopedTitleTerms: scopedTitles,
            scopedSeriesTerms: scopedSeries,
            semanticPhrase: semantic
        )
        query.excludedTagTerms = excludedTags
        query.excludedAuthorTerms = excludedAuthors
        query.excludedTitleTerms = excludedTitles
        query.excludedSeriesTerms = excludedSeries
        query.wordCountGT = wordGT
        query.wordCountLT = wordLT
        return query
    }

    private static func parseWordCount(_ str: String) -> Int? {
        let lower = str.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasSuffix("k") {
            let num = String(lower.dropLast())
            if let doubleVal = Double(num) {
                return Int(doubleVal * 1000)
            }
        }
        return Int(lower)
    }

    /// Splits input into tokens while respecting double quotes (e.g. `tag:"Slow Burn"`).
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in input {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// Removes any `fulltext:...` token from the search text, preserving other tokens and quotes.
    static func removingFulltext(from input: String) -> String {
        let tokens = tokenize(input)
        let filtered = tokens.filter { !$0.lowercased().hasPrefix("fulltext:") }
        return filtered.joined(separator: " ").trimmingCharacters(in: .whitespaces)
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
