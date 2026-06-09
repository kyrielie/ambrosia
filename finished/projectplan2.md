# Project Ambrosia — Final Adjustment Plan (Condensed)

Read before each session:
- Implement one major section per session.
- Run xcodebuild before claiming completion.
- Write a handoff block with build output.
- Follow invariants.

## Completed
- 8A (Section A) — Complete
- 8B (Sections F, G) — Complete
- 8C-1 (B1 Context Menu) — Complete
- 8C-2 (B2 Unified Annotations) — Complete
- 8D (Section C) — Complete
- 8E-1 (D1 Native Toolbar) — Complete
- 8E-2 (D2 Email View) — Complete
- 8E-3 (D3 Ranking View Scaffold) — Complete
- 8F (Section E Window Size Preferences) — Complete

Remove/reduce legacy detail for completed sections. Do not revisit unless fixing regressions.

## Invariants
1. No bare Swift collections on @Model.
2. No cross-context model lookups.
3. Use named ModelConfiguration.
4. No ModelContext.reset().
5. UTF-16 offsets for annotations.
6. books table has no series column.
7. SQL bindings use [Binding?].
8. Read-only Calibre DB; no write PRAGMAs.
9. Never hand-edit Package.resolved.
10. evaluateJavaScript uses completionHandler.
11. Register new Swift files in project.pbxproj.
12. Check SwiftData docs before @Model changes.

## Section H — Settings: Pagination Mode Toggle

### What it controls

`ReaderPreferences.shared.defaultReadingMode` is a **global override** — it applies to
every book on every open, ignoring per-book `BookState.readingModeRaw`. This means the
per-book mode stored in `BookState` becomes unused once this preference exists; the reader
always reads from `ReaderPreferences` instead of `BookState`.

### `Reader/ReaderPreferences.swift`

Add a new `ReadingMode` enum (move it here from `BookState.swift` since it's now a
preference, not per-book state):

```swift
enum ReadingMode: String, CaseIterable, Identifiable {
    case scroll    = "scroll"
    case paginated = "paginated"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scroll:    return "Scroll"
        case .paginated: return "Paginated"
        }
    }
}
```

Add the stored preference:

```swift
@Published var defaultReadingMode: ReadingMode {
    didSet { UserDefaults.standard.set(defaultReadingMode.rawValue,
                                       forKey: Keys.defaultReadingMode) }
}

// In Keys enum:
static let defaultReadingMode = "rp.defaultReadingMode"

// In Defaults enum:
static let defaultReadingMode = ReadingMode.scroll

// In init():
let rawMode = ud.string(forKey: Keys.defaultReadingMode) ?? Defaults.defaultReadingMode.rawValue
defaultReadingMode = ReadingMode(rawValue: rawMode) ?? .scroll

// In resetToDefaults():
defaultReadingMode = Defaults.defaultReadingMode
```

### `Reader/ReaderViewController.swift`

Replace all reads of `bookState?.readingMode` (or `bookState?.readingModeRaw`) with
`ReaderPreferences.shared.defaultReadingMode` when deciding the initial mode at load time.
The per-book `BookState.readingModeRaw` field is no longer read; it can remain in the
model for now (removing it would require a SwiftData migration) but is ignored.

In `loadScrollMode()` / `loadPaginatedMode()` calls, keep the mode-switch buttons in the
reader toolbar functional so the user can still switch mode per-reading-session — but
on the *next* open, `ReaderPreferences.shared.defaultReadingMode` wins again.

Do **not** write back to `BookState.readingModeRaw` any more (that was what kept the
per-book mode). Remove those write-backs.

### `Preferences/PreferencesWindowController.swift`

Add to the Reading section, above "When preferences change":

```
Default reading mode     ( ) Scroll   (•) Paginated
```

Use a `Picker` with `.radioGroupStyle()` or a `Picker` with `.segmented` style:

```swift
Picker("Default reading mode", selection: $prefs.defaultReadingMode) {
    ForEach(ReadingMode.allCases) { mode in
        Text(mode.label).tag(mode)
    }
}
.pickerStyle(.segmented)
```

### `Database/Models/BookState.swift`

Remove the `readingModeRaw` field and the `readingMode` computed accessor. Because
removing a stored property from a SwiftData `@Model` requires a migration schema version
bump, instead mark it `@Transient` or just leave the stored column orphaned in the DB
(SwiftData ignores extra columns). The safest path with no migration risk:

**Keep `readingModeRaw: String` in the model but stop reading or writing it.**
Delete the `readingMode: ReadingMode` computed accessor so no code references it.
The DB column becomes inert. Document this with a comment:
```swift
// Legacy — superseded by ReaderPreferences.shared.defaultReadingMode (global override).
// Not removed to avoid SwiftData migration. Never read or written.
var readingModeRaw: String = "scroll"
```

---

## Section I — Search: Autocomplete, Prefix Syntax, Full-Text Search

Split into three sub-sessions: I1 (query parser + prefix stacking), I2 (autocomplete UI),
I3 (FTS5 integration). Confirm each builds before starting the next.

### I1 — Search Query Parser

The search field currently passes a raw string to `CalibreLibrary.fuzzyTitleCondition(for:)`.
The new parser sits in front of that and intercepts prefix tokens before they reach the
fuzzy search. Non-prefixed tokens still go through `fuzzyTitleCondition`.

**`Database/SearchQueryParser.swift`** (new file)

```swift
/// Parses a free-form search string into structured tokens.
///
/// Supported syntax:
///   tag:action              → books whose tag list contains "action"
///   author:rowling          → books whose author name contains "rowling"
///   title:goblet            → books whose title contains "goblet"
///   tag:action author:jo    → AND logic: both conditions must match
///   goblet fire             → plain fuzzy title/author search (unchanged)
///   tag:action goblet       → tag filter AND plain fuzzy on "goblet"
///
/// Prefix tokens stack additively. They also combine additively with any
/// active FilterDrawer rules (the caller merges them into the same SQL).
struct SearchQuery {
    let tagTerms:     [String]   // one SQL LIKE condition per term
    let authorTerms:  [String]
    let titleTerms:   [String]
    let plainTerms:   [String]   // remainder → fuzzyTitleCondition per term
    var isEmpty: Bool {
        tagTerms.isEmpty && authorTerms.isEmpty && titleTerms.isEmpty && plainTerms.isEmpty
    }
}

struct SearchQueryParser {

    static func parse(_ input: String) -> SearchQuery {
        var tags: [String] = [], authors: [String] = [],
            titles: [String] = [], plain: [String] = []

        // Tokenise on whitespace. Quoted values ("foo bar") treated as one token.
        let tokens = tokenise(input)

        for token in tokens {
            if let value = token.dropPrefix("tag:"),    !value.isEmpty { tags.append(value) }
            else if let value = token.dropPrefix("author:"), !value.isEmpty { authors.append(value) }
            else if let value = token.dropPrefix("title:"),  !value.isEmpty { titles.append(value) }
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

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
```

**`Database/CalibreLibrary.swift`** — update `_fetchBooks` and `bookCount`

Add a new internal method that takes a `SearchQuery` instead of a raw `String`:

```swift
func books(offset: Int, limit: Int, sort: SortField, ascending: Bool,
           query: SearchQuery) -> [CalibreBook]
```

Build the SQL WHERE clause from the query:

```swift
private func whereClause(for query: SearchQuery) -> (String, [Binding?]) {
    var clauses: [String] = []
    var args: [Binding?]  = []

    // tag: terms — each requires a subquery or join
    for term in query.tagTerms {
        clauses.append("""
            EXISTS (
                SELECT 1 FROM books_tags_link btl2
                JOIN tags t2 ON t2.id = btl2.tag
                WHERE btl2.book = b.id AND LOWER(t2.name) LIKE ?
            )
            """)
        args.append("%\(term.lowercased())%" as Binding?)
    }

    // author: terms
    for term in query.authorTerms {
        clauses.append("""
            EXISTS (
                SELECT 1 FROM books_authors_link bal2
                JOIN authors a2 ON a2.id = bal2.author
                WHERE bal2.book = b.id AND LOWER(a2.name) LIKE ?
            )
            """)
        args.append("%\(term.lowercased())%" as Binding?)
    }

    // title: terms
    for term in query.titleTerms {
        clauses.append("LOWER(b.title) LIKE ?")
        args.append("%\(term.lowercased())%" as Binding?)
    }

    // plain terms — existing fuzzy title logic
    if !query.plainTerms.isEmpty {
        let joined = query.plainTerms.joined(separator: " ")
        let (fuzzyClause, fuzzyArgs) = CalibreLibrary.fuzzyTitleCondition(for: joined)
        clauses.append(fuzzyClause)
        args.append(contentsOf: fuzzyArgs)
    }

    if clauses.isEmpty { return ("", []) }
    return (clauses.joined(separator: " AND "), args)
}
```

Update `_fetchBooks` to call `whereClause(for:)` when a `SearchQuery` is present.
Maintain the existing `String?` overload for backwards compatibility — it wraps the
string in `SearchQueryParser.parse()` before delegating to the new path.

**`LibraryUI/BookGridItem.swift`** (and `LibraryToolbarState.swift` once D1 is built)

Parse the search text on every debounce tick before passing to `loadPage`:

```swift
private func loadPage() {
    let query = SearchQueryParser.parse(searchText)
    // Pass query to library.books(offset:limit:sort:ascending:query:)
    ...
}
```

Prefix tokens stack additively with `activeFilterResult`. The `FilterBuilder` produces a
list of calibre IDs; the new search layer then filters those IDs further using the WHERE
clause from `whereClause(for:)`. Concretely, when `activeFilterResult` is non-nil, use
`library.books(ids: result.calibreIDs, ..., query: query)` — add the query WHERE clause
as an additional AND condition inside the existing `ids`-based query.

### I2 — Autocomplete Suggestions

**Rules from design review:**
- Tag suggestions: appear while typing plain text (before any prefix), showing matching
  tags from the library.
- Author suggestions: appear only after the user types `author:` prefix.
- Title suggestions: appear only after the user types `title:` prefix.
- Plain text shows tag suggestions only (not author or title — those are too numerous
  and noisy).

**`Database/CalibreLibrary.swift`** — add three suggestion methods:

```swift
/// Tags whose name contains `prefix`, up to `limit` results.
/// Used for autocomplete. Sorted by frequency (most-used tags first).
func tagSuggestions(prefix: String, limit: Int = 8) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let sql = """
        SELECT t.name, COUNT(btl.book) AS freq
        FROM tags t
        JOIN books_tags_link btl ON btl.tag = t.id
        WHERE LOWER(t.name) LIKE ?
        GROUP BY t.id
        ORDER BY freq DESC
        LIMIT ?
        """
    let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                       limit as Binding?]).map { $0 }) ?? []
    return rows.compactMap { $0[0] as? String }
}

/// Author names containing `prefix`, up to `limit` results.
func authorSuggestions(prefix: String, limit: Int = 8) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let sql = """
        SELECT a.name FROM authors a
        WHERE LOWER(a.name) LIKE ?
        ORDER BY a.sort
        LIMIT ?
        """
    let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                       limit as Binding?]).map { $0 }) ?? []
    return rows.compactMap { $0[0] as? String }
}

/// Book titles containing `prefix`, up to `limit` results.
func titleSuggestions(prefix: String, limit: Int = 8) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let sql = "SELECT title FROM books WHERE LOWER(title) LIKE ? ORDER BY title LIMIT ?"
    let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                       limit as Binding?]).map { $0 }) ?? []
    return rows.compactMap { $0[0] as? String }
}
```

**`LibraryUI/SearchSuggestionsView.swift`** (new SwiftUI file)

A floating overlay List shown below the search field when suggestions are available.
Presented as a `.popover` or absolutely-positioned overlay — do NOT use `NSPopover`
(which requires an anchor view); use a SwiftUI overlay with `ZStack` alignment.

```swift
struct SearchSuggestionsView: View {
    let suggestions: [SearchSuggestion]
    let onSelect: (SearchSuggestion) -> Void

    var body: some View {
        if suggestions.isEmpty { EmptyView() } else {
            VStack(spacing: 0) {
                ForEach(suggestions) { s in
                    Button { onSelect(s) } label: {
                        HStack {
                            Image(systemName: s.kind.icon).foregroundStyle(.secondary)
                            Text(s.displayText)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 8)
            .frame(maxWidth: 380)
        }
    }
}

struct SearchSuggestion: Identifiable {
    let id = UUID()
    let kind: SuggestionKind
    let value: String      // the tag/author/title name

    var displayText: String { value }

    /// When selected, this text is appended/inserted into the search field.
    /// Tags are inserted as plain text (no prefix); authors/titles get their prefix.
    var insertText: String {
        switch kind {
        case .tag:    return value
        case .author: return "author:\"\(value)\""
        case .title:  return "title:\"\(value)\""
        }
    }
}

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
```

**Suggestion logic in `LibraryRootView` (or `LibraryToolbarState`):**

On every `searchText` change (debounced, 150 ms — faster than the page-load debounce):

```swift
private func updateSuggestions() {
    guard let library = session.library else { suggestions = []; return }
    let q = searchText

    // Detect which prefix (if any) the cursor is in
    if let prefix = q.activePrefixValue(for: "author:") {
        suggestions = library.authorSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .author, value: $0) }
    } else if let prefix = q.activePrefixValue(for: "title:") {
        suggestions = library.titleSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .title, value: $0) }
    } else {
        // Plain text — show tag suggestions for the last word typed
        let lastWord = q.components(separatedBy: .whitespaces).last ?? ""
        if lastWord.count >= 2 {
            suggestions = library.tagSuggestions(prefix: lastWord)
                .map { SearchSuggestion(kind: .tag, value: $0) }
        } else {
            suggestions = []
        }
    }
}
```

`activePrefixValue(for:)` is a `String` extension that returns the typed value after the
last occurrence of the given prefix in the string, or `nil` if that prefix isn't present.

When the user selects a suggestion, `onSelect` inserts `suggestion.insertText` into the
search string appropriately (replacing the triggering fragment), then clears the suggestion list.

### I3 — Full-Text Search (FTS5)

**Architecture:** `CalibreFTSLibrary` is a separate, optional connection to
`full-text-search.db` in the same directory as `metadata.db`. It is opened lazily and
silently dropped if the file doesn't exist or is structurally invalid. The caller (search
path) never knows or cares whether FTS was used.

**`Database/CalibreFTSLibrary.swift`** (new file)

```swift
/// Optional read-only connection to Calibre's full-text-search.db.
/// Returns nil from the initialiser if the file doesn't exist or
/// lacks the expected FTS5 tables — caller falls back to SQL LIKE search.
final class CalibreFTSLibrary {

    private let db: Connection

    init?(libraryURL: URL) {
        let ftsURL = libraryURL.appendingPathComponent("full-text-search.db")
        guard FileManager.default.fileExists(atPath: ftsURL.path),
              let conn = try? Connection(ftsURL.path, readonly: true)
        else { return nil }

        // Validate that the expected tables exist
        let tables = (try? conn.prepare("SELECT name FROM sqlite_master WHERE type='table'")
            .map { $0[0] as? String ?? "" }) ?? []
        guard tables.contains("books_fts") && tables.contains("books_fts_map")
        else { return nil }

        self.db = conn
    }

    /// Returns calibre book IDs whose full text matches the query.
    /// Uses FTS5 MATCH syntax: multi-word queries use implicit AND.
    /// Returns nil on any error — caller falls back to LIKE search.
    func search(query: String, limit: Int = 500) -> [Int]? {
        // Sanitise query for FTS5 MATCH: remove special chars, wrap in quotes
        let sanitised = query
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }         // quote each word to prevent FTS5 syntax errors
            .joined(separator: " ")
        guard !sanitised.isEmpty else { return nil }

        let sql = """
            SELECT m.book FROM books_fts_map m
            JOIN books_fts ON books_fts.rowid = m.id
            WHERE books_fts MATCH ?
            LIMIT ?
            """
        return try? db.prepare(sql, [sanitised as Binding?, limit as Binding?])
            .compactMap { row -> Int? in
                guard let v = row[0] else { return nil }
                if let i = v as? Int64 { return Int(i) }
                if let i = v as? Int   { return i }
                return nil
            }
    }
}
```

**`Database/LibrarySession.swift`**

Add an optional `ftsLibrary: CalibreFTSLibrary?` property. Initialise it in `open(url:)`
after the main `CalibreLibrary` connection succeeds:

```swift
ftsLibrary = CalibreFTSLibrary(libraryURL: url)
```

Set to `nil` in the close path.

**Integration into search flow — `LibraryUI/BookGridItem.swift` (or `loadPage`)**

When `plainTerms` is non-empty, attempt FTS before falling back to SQL LIKE:

```swift
private func resolvedQuery(_ query: SearchQuery) -> SearchQuery {
    guard !query.plainTerms.isEmpty,
          let fts = session.ftsLibrary
    else { return query }

    let plainText = query.plainTerms.joined(separator: " ")
    guard let ftsIDs = fts.search(query: plainText), !ftsIDs.isEmpty else {
        return query   // FTS returned nothing or failed — use LIKE fallback
    }

    // Replace plain terms with an explicit ID constraint.
    // Return a modified query with no plain terms (they've been resolved to IDs)
    // and store the FTS IDs for the caller to pass as an id-set filter.
    // Implementation: expose ftsMatchedIDs on the resolved query.
    return SearchQuery(tagTerms: query.tagTerms, authorTerms: query.authorTerms,
                       titleTerms: query.titleTerms, plainTerms: [],
                       ftsMatchedIDs: ftsIDs)
}
```

Add `ftsMatchedIDs: [Int]?` to `SearchQuery`. When non-nil, `loadPage` intersects these
IDs with the active filter result IDs (if any) and passes the intersection to
`library.books(ids:...)`.

**FTS-specific behaviour:**
- FTS is only used for `plainTerms`. Prefix-syntax tokens (`tag:`, `author:`, `title:`)
  always go through SQL.
- If FTS returns >500 results, truncate to 500 and let the SQL WHERE clause refine further.
- If FTS search errors (corrupt DB, schema mismatch), `CalibreFTSLibrary.search` returns
  `nil` and `resolvedQuery` returns the original query unchanged — LIKE fallback fires
  transparently.
- `full-text-search.db` is opened **read-only**. No write PRAGMAs ever.

**Invariant to add** (Section I3 specific):
> `CalibreFTSLibrary` opened `readonly: true`. Never write to it. Never PRAGMA it.
> Search returns nil on any error — caller always has a LIKE fallback.

---

## Updated implementation order

| Session | Section | Size | Status |
|---|---|---|---|
| 8A | A — Custom column bug fix | Small | ✅ Complete |
| 8B | F — NOT filter chip; G — Dock reopen | Small | ✅ Complete |
| 8C-1 | B1 — Context menu | Small | ⚠️ Partially attempted — run diagnostic before proceeding |
| 8C-2 | B2 — Unified annotation model + sidebar + popover | Large | Not started |
| 8D | C — Font picker + reload strategy | Medium | Not started |
| 8E-1 | D1 — LibraryToolbarState + NSToolbar | Medium | Not started |
| 8E-2 | D2 — Email view | Large | Not started |
| 8E-3 | D3 — Grid view + cover art | Medium | Not started |
| 8F | E — Window size preference | Small | Not started |
| 8G | H — Pagination mode toggle in Settings | Small | Not started |
| 8H-1 | I1 — SearchQueryParser + prefix SQL | Medium | Not started |
| 8H-2 | I2 — Autocomplete suggestions UI | Medium | Not started |
| 8H-3 | I3 — FTS5 integration | Medium | Not started |

Do not start 8C-2 until 8C-1 produces a clean `xcodebuild` and the handoff block contains the build output.
Do not start 8E-2 until 8E-1 builds cleanly.
