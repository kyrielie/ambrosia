import SQLite
import Foundation

// MARK: - Sort field

enum SortField: String, CaseIterable, Identifiable {
    case title
    case author
    case wordCount
    case kudos
    case published      // Unified published date (archive metadata -> Calibre pubdate)
    case updated        // Unified updated date (archive updated -> archive published -> Calibre pubdate)
    case random         // Seeded random order
    case relevance      // Contextual relevance rank for search and filter results

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:     return "Title"
        case .author:    return "Author"
        case .wordCount: return "Word Count"
        case .kudos:     return "Kudos"
        case .published: return "Date Published"
        case .updated:   return "Date Updated"
        case .random:    return "Random"
        case .relevance: return "Relevance"
        }
    }

    /// User-facing active cases presented in UI sort pickers and menus.
    static var userFacingCases: [SortField] {
        [.relevance, .title, .author, .wordCount, .kudos, .published, .updated, .random]
    }
}

// MARK: - CalibreLibrary

/// Read-only query layer over Calibre's metadata.db.
/// All queries are synchronous — SQLite on a local file returns in <1ms.
/// One instance per open library; replaced wholesale when the user switches libraries.
///
/// Actor-isolated: all queries serialize automatically. See AmbrosiaMetaDB for the
/// equivalent pattern (Database/AmbrosiaMetaDB.swift).
actor CalibreLibrary {

    let root: URL                   // absolute path to the Calibre library folder
    /// Replaced by `reopenIfFileReplaced()` when Calibre swaps the file; the
    /// setter stays private so only this file can do that.
    internal private(set) var db: Connection
    /// `(st_dev, st_ino)` of `metadata.db` when `db` was opened. Read before
    /// opening so a replacement racing the open is caught on the next check.
    private var dbIdentity: CalibreFileIdentity?

    // MARK: - AO3 metadata caches
    //
    // `AmbrosiaMetaDB` is the sole owner of ambrosia_meta.db (Invariant 10).
    // CalibreLibrary used to open its own read-only `Connection` to that file,
    // which violated that ownership boundary. These three caches are bulk-
    // fetched by `AmbrosiaMetaDB` and pushed in by `LibrarySession` (on open
    // and after AO3 extraction completes) via `updateAO3MetaCaches`. The
    // methods below read from these caches instead of querying a database.
    private(set) var ao3WordCountCache: [Int: Int] = [:]
    private(set) var ao3KudosCache: [Int: Int] = [:]
    private(set) var ao3DateCache: [Int: (published: String?, updated: String?)] = [:]
    private(set) var crossoverIDCache: Set<Int> = []
    private(set) var ao3WorkIDCache: [Int: String] = [:]

    /// Non-winning calibre IDs of any AO3-work duplicate group, computed via
    /// `DuplicateBookDetector` whenever `ao3WorkIDCache`/`ao3DateCache` are
    /// refreshed (see `updateAO3MetaCaches`). Consumed as
    /// `LibraryVisibilityPolicy.duplicateLoserIDs` when the "Deduplicate
    /// books" preference is on.
    private(set) var duplicateLoserIDCache: Set<Int> = []

    /// In-memory cache for fast, nonisolated autocomplete suggestions across tags, authors, and series.
    nonisolated let suggestionStore = SuggestionStore()

    /// §6: Seeded random sort seed. Stable within a session; refreshed on library open
    /// or when the user explicitly requests a new shuffle.
    private(set) var randomSeed: UInt64 = UInt64.random(in: 0 ... UInt64.max)

    init(root: URL) throws {
        self.root = root
        let dbPath = root.appendingPathComponent("metadata.db").path
        dbIdentity = CalibreFileIdentity.of(path: dbPath)
        db = try Self.openConnection(path: dbPath)
    }

    private static func openConnection(path: String) throws -> Connection {
        let connection = try Connection(path, readonly: true)
        connection.busyTimeout = 5.0
        SQLiteRegexRegistration.register(on: connection)
        // Increase the page cache to 32 MB and keep temp tables in memory.
        // These are session-scoped PRAGMAs, safe on a read-only connection.
        try? connection.execute("PRAGMA cache_size = -32768")   // negative = kibibytes
        try? connection.execute("PRAGMA temp_store = MEMORY")
        return connection
    }

    /// Reopens the read-only connection when `metadata.db` was deleted and
    /// recreated (restore, copy over), the same file-identity check
    /// `CalibreFTSLibrary` makes. An open connection would keep reading the
    /// unlinked old file. Returns true only when a reopen happened; a failed
    /// reopen keeps the old connection and returns false, so the next call
    /// tries again. In-place writes by Calibre need no reopen: a new read
    /// transaction sees them.
    func reopenIfFileReplaced() -> Bool {
        let path = root.appendingPathComponent("metadata.db").path
        guard let current = CalibreFileIdentity.of(path: path), current != dbIdentity else { return false }
        guard let fresh = try? Self.openConnection(path: path) else { return false }
        db = fresh
        dbIdentity = current
        clearQueryCaches()
        suggestionStore.invalidate()
        return true
    }

    /// Drops every cache derived from `metadata.db` contents. The AO3-derived
    /// maps are untouched; they come from `AmbrosiaMetaDB`.
    func clearQueryCaches() {
        pageCache.removeAll()
        countCache.removeAll()
        groupAwareCountCache.removeAll()
        invalidateSortedIDs()
    }

    /// Called by `LibrarySession` whenever the AO3 metadata caches should be
    /// refreshed from `AmbrosiaMetaDB` (on library open and after extraction
    /// batches complete).
    func updateAO3MetaCaches(
        wordCounts: [Int: Int],
        kudos: [Int: Int],
        dates: [Int: (published: String?, updated: String?)],
        crossoverIDs: Set<Int>,
        workIDs: [Int: String]
    ) {
        ao3WordCountCache = wordCounts
        ao3KudosCache = kudos
        ao3DateCache = dates
        crossoverIDCache = crossoverIDs
        ao3WorkIDCache = workIDs
        duplicateLoserIDCache = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)
        // §Phase3: word-count-sorted pages and any page/count keyed on this
        // library's AO3 fields are now stale. Same actor reaching into its own
        // state, no version plumbing needed (see LRUCache note above pageCache).
        clearQueryCaches()
    }

    /// §6.2: last error from a search/count query, if any. Set by `bookCount(query:)`
    /// and the `bookCount(query:filter:)` sibling in FilterBuilder.swift on failure,
    /// cleared on the next successful call to either. Minimum-viable error surfacing
    /// (Phase 6.2 of the gap closure plan) — not a full `throws` refactor of the
    /// search/count path. Read cross-actor via `LibrarySession.refreshLastSearchError()`,
    /// since `CalibreLibrary` (an actor) cannot mutate `LibrarySession.lastError`
    /// (a `@MainActor` property) directly.
    private(set) var lastSearchError: String?

    /// §6.2: records a search/count failure. Actor-isolated call, safe to invoke
    /// from any method on this actor.
    func recordSearchError(_ message: String) {
        lastSearchError = message
    }

    /// §6.2: clears the last recorded search/count error, e.g. after a successful query.
    func clearSearchError() {
        lastSearchError = nil
    }

    // MARK: - §Phase3: Page/count result cache
    //
    // Declared at default (internal) visibility, NOT private: bookCount(query:filter:)
    // lives in an extension in FilterDrawer/FilterBuilder.swift, a different file,
    // and `private` here would make these invisible there.
    //
    // Invalidation:
    //  - Library switch/close: free, this whole actor instance is replaced.
    //  - Membership change (like/skip/read-later/collection/series sync): the
    //    caller passes the current visibility version and pinned collection
    //    version into cached methods below, so stale entries never match after
    //    a visibility change or a user-applied query snapshot change.
    //  - AO3 extraction batch completes: updateAO3MetaCaches(...) clears both
    //    caches directly (same actor, no version plumbing needed).
    //  - Random reshuffle: covered by randomSeed being part of the key.
    var pageCache: LRUCache<PageCacheKey, (page: [CalibreBook], hasMore: Bool)> = LRUCache(limit: 48)
    var countCache: LRUCache<CountCacheKey, Int> = LRUCache(limit: 48)
    var groupAwareCountCache: LRUCache<GroupAwareCountCacheKey, Int> = LRUCache(limit: 48)

    /// Full sorted id list per view (everything in `PageCacheKey` except the
    /// paging window), so paging within one view costs a slice plus
    /// `booksForIDs`, not a fresh materialize-and-sort. Each entry can hold
    /// tens of thousands of ints, so the capacity is deliberately small.
    /// Read through `get` so eviction is true LRU.
    var sortedIDsCache: LRUCache<SortedIDsCacheKey, [Int]> = LRUCache(limit: 8)
    private(set) var sortedIDsComputeCount: Int = 0
    /// Sorts currently being computed. A second same-key caller (for example a
    /// prefetch racing a page change) awaits the running task instead of
    /// starting another full sort. `groupAwareTitleSortedPage` suspends mid
    /// computation, so without this two callers can both run the whole sort.
    private var sortedIDsInFlight: [SortedIDsCacheKey: Task<[Int], Never>] = [:]
    /// Bumped on invalidation. A sort that started before the bump must not
    /// store its (stale) result into the cache.
    private var sortedIDsGeneration = 0

    /// Drops every cached sorted list and forgets in-flight sorts. Callers
    /// already awaiting an in-flight task still receive its result for that
    /// one call, but it is not stored.
    func invalidateSortedIDs() {
        sortedIDsGeneration += 1
        sortedIDsCache.removeAll()
        sortedIDsInFlight.removeAll()
    }

    // MARK: - Count

    /// Total books. Called once on open and refreshed after debounced search.
    func bookCount() -> Int {
        let rows = (try? db.prepare("SELECT COUNT(*) FROM books").map { $0 }) ?? []
        return (rows.first?.first as? Int64).map(Int.init) ?? 0
    }

    /// Cheap change marker for `metadata.db` (see `LibraryFingerprint`). Nil when
    /// the aggregate query fails, which callers treat as "unknown, do not skip".
    /// `MAX(last_modified)` is probably unindexed in Calibre's schema, so this is
    /// one pass over `books`; it is signposted so Phase 0 can time it.
    func libraryFingerprint() -> LibraryFingerprint? {
        let signpost = LaunchSignposts.begin("fingerprint.compute")
        defer { LaunchSignposts.end("fingerprint.compute", signpost) }
        let path = root.appendingPathComponent("metadata.db").path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let sql = "SELECT COUNT(*), COALESCE(MAX(id), 0), COALESCE(MAX(last_modified), '') FROM books"
        guard let rows = try? db.prepare(sql).map({ $0 }), let row = rows.first,
              let count = row[0] as? Int64, let maxID = row[1] as? Int64 else { return nil }
        return LibraryFingerprint(fileModified: modified, fileSize: size, bookCount: Int(count),
                                  maxBookID: Int(maxID), maxLastModified: (row[2] as? String) ?? "")
    }

    func allBookIDs() -> [Int] {
        let rows = (try? db.prepare("SELECT id FROM books ORDER BY id").map { $0 }) ?? []
        return rows.compactMap { row in
            if let value = row.first as? Int64 { return Int(value) }
            return row.first as? Int
        }
    }

    func allCalibreSeriesEntries() -> [SeriesCacheWriteInput] {
        calibreSeriesEntries(bookIDsAfter: nil, through: nil)
    }

    /// Calibre series memberships for books with `lower < id <= upper` (either
    /// bound optional). Chunked callers walk id windows so each actor hop is
    /// short and queued page fetches can run between them. Windowing by book id
    /// (not row count) never splits one book's memberships across two chunks.
    /// Ordered by book, then series name, so a book with several series keeps
    /// the same winner under insert-if-absent as the old global `s.name` order.
    func calibreSeriesEntries(bookIDsAfter lower: Int?, through upper: Int?) -> [SeriesCacheWriteInput] {
        var bounds = ""
        if let lower { bounds += " AND b.id > \(lower)" }
        if let upper { bounds += " AND b.id <= \(upper)" }
        let sql = """
        SELECT b.id, s.id, s.name, b.series_index
        FROM books b
        JOIN books_series_link bsl ON bsl.book = b.id
        JOIN series s ON s.id = bsl.series
        WHERE s.name IS NOT NULL AND TRIM(s.name) != ''\(bounds)
        ORDER BY b.id, s.name, b.series_index
        """
        let rows = (try? db.prepare(sql).map { $0 }) ?? []
        return rows.compactMap { row in
            guard let idBind = row[0] as? Int64,
                  let seriesIDBind = row[1] as? Int64,
                  let name = row[2] as? String else { return nil }
            // Calibre natively supports fractional series_index (unlike
            // series_cache.series_index, which is Int). A fractional value
            // here indicates unexpected/bad data for this library, not a
            // case to silently truncate (which would collide, e.g. 1.5 ->
            // 1, with book #1). Exclude only this series membership row —
            // the book still appears via any other valid membership or as a
            // standalone item. See Bug 3 decision log.
            let rawIndex: Double
            if let doubleValue = row[3] as? Double {
                rawIndex = doubleValue
            } else if let int64Value = row[3] as? Int64 {
                rawIndex = Double(int64Value)
            } else {
                rawIndex = 1
            }
            guard rawIndex.truncatingRemainder(dividingBy: 1) == 0 else {
                #if DEBUG
                print("[allCalibreSeriesEntries] DIAGNOSTIC fractional series_index: book=\(idBind) series=\(name) value=\(rawIndex)")
                #endif
                return nil
            }
            return SeriesCacheWriteInput(
                calibreID: Int(idBind),
                seriesName: name,
                seriesIndex: Int(rawIndex),
                ao3SeriesID: nil,
                isAnthology: false,
                calibreSeriesID: Int(seriesIDBind)
            )
        }
    }

    func anthologyBookIDs() -> Set<Int> {
        // Cheap SQL prefilter: loose, unanchored candidate net over the raw HTML
        // comment column. Comment blobs are large, so we don't want to fetch every
        // one — this LIKE is still a cheap single-column scan.
        let rows = (try? db.prepare(
            """
            SELECT book, text
            FROM comments
            WHERE LOWER(text) LIKE '%anthology%'
            """
        ).map { $0 }) ?? []
        var result = Set<Int>()
        for row in rows {
            guard let text = row[1] as? String else { continue }
            let bookID: Int?
            if let value = row[0] as? Int64 { bookID = Int(value) } else { bookID = row[0] as? Int }
            guard let id = bookID else { continue }
            // Real, accurate check against HTML-stripped text, using the same
            // anchored detector CalibreBook.isDescriptionAnthology uses, so the
            // two checks can never drift apart.
            if AnthologyDetector.isAnthology(rawComment: text) {
                result.insert(id)
            }
        }
        return result
    }

    func ao3PublisherBookIDs() -> Set<Int> {
        let sql = """
        SELECT bpl.book
        FROM books_publishers_link bpl
        JOIN publishers p ON p.id = bpl.publisher
        WHERE TRIM(p.name) = 'Archive of Our Own'
        """
        let rows = (try? db.prepare(sql).map { $0 }) ?? []
        return Set(rows.compactMap { row in
            if let value = row[0] as? Int64 { return Int(value) }
            return row[0] as? Int
        })
    }

    // MARK: - §6: Crossover book IDs
    //
    // A "crossover" is any work tagged with more than one fandom in ao3_metadata.
    // We inspect fandoms_json (a JSON array) — if it decodes to an array with count > 1
    // the book is a crossover. We use SQLite's JSON1 extension: json_array_length().
    // If JSON1 is unavailable (should not happen on macOS 14+) we fall back to an
    // in-memory scan of all IDs and return empty so filtering is a no-op rather than crash.
    func crossoverBookIDs() -> Set<Int> {
        crossoverIDCache
    }

    /// Non-winning calibre IDs of any AO3-work duplicate group. See
    /// `DuplicateBookDetector` and `duplicateLoserIDCache` above.
    func duplicateLoserBookIDs() -> Set<Int> {
        duplicateLoserIDCache
    }

    // MARK: - §6: Seeded random sort helpers

    /// Replace the current random seed, producing a new shuffle order.
    func reshuffleRandom() {
        randomSeed = UInt64.random(in: 0 ... UInt64.max)
    }

    /// Sort an array of calibre IDs using a stable seeded shuffle (Xorshift64 + Fisher-Yates).
    /// Deterministic for the same seed — same session always sees the same order.
    func sortedRandomly(_ ids: [Int]) -> [Int] {
        var rng = SeededRNG(seed: randomSeed)
        var arr = ids
        for currentIndex in stride(from: arr.count - 1, through: 1, by: -1) {
            let swapIndex = Int(rng.next() % UInt64(currentIndex + 1))
            arr.swapAt(currentIndex, swapIndex)
        }
        return arr
    }

    // MARK: - §6: orderByClause — updated with new sort cases
    // ao3Published / ao3Updated: sort is resolved in-memory post-fetch via sortedByAO3Date.
    // SQL only needs a stable title-order baseline here; the cross-database JOIN that was
    // previously attempted here against ao3_metadata was always invalid (ao3_metadata lives
    // in ambrosia_meta.db, not metadata.db) and caused fetchBooksInternal to throw, returning [].
    //
    // Every case ends with `, b.id ASC` (book id is unique and already indexed) so ties on
    // the primary sort key -- e.g. two books sharing a title, the same kudos count, or the
    // same series_index -- resolve to a fixed order. Without this, a JSON feed's next_url
    // pagination re-runs this full query from scratch on every page; SQLite doesn't guarantee
    // tied rows come back in the same relative order across separate executions of the same
    // query, so the page boundaries computed by paginate(_:page:maxBooksPerPage:) could shift
    // between page N and page N+1 of the same refresh, letting a book fall into the gap
    // between two pages (never returned in any page) or appear in two different pages.
    func orderByClause(sort: SortField, direction: String) -> String {
        switch sort {
        case .title:
            return "b.title \(direction), b.id ASC"
        case .author:
            return "MIN(a.sort) \(direction), b.title ASC, b.id ASC"
        case .wordCount:
            // Word-count sort is resolved entirely in Swift via wordCountSortedPage.
            // SQL only needs a stable baseline order here.
            return "b.title \(direction), b.id ASC"
        case .kudos:
            return "COALESCE(k.value, 0) \(direction), b.id ASC"
        case .published, .updated:
            return "b.pubdate \(direction), b.id ASC"
        case .random:
            // Seeded random is handled post-fetch in the caller (sortedRandomly).
            return "b.title ASC, b.id ASC"
        case .relevance:
            // Relevance sort is resolved in Swift via relevanceSortedPage.
            // SQL only needs a stable baseline order here.
            return "b.title \(direction), b.id ASC"
        }
    }

    /// Returns whether this library has any kudos custom column or cached kudos counts.
    var hasKudosData: Bool {
        if let label = CustomColumnConfig.shared.kudosLabel,
           customColumnTableName(label: label) != nil {
            return true
        }
        return !ao3KudosCache.isEmpty
    }

    // MARK: - §6: Shared AO3 metadata sort helper

    /// Returns the table name for the kudos custom column.
    func kudosCustomColumnTable() -> String? {
        let label = CustomColumnConfig.shared.kudosLabel ?? "kudos"
        return customColumnTableName(label: label)
    }

    // MARK: - §6: Bulk AO3 word-count fallback
    //
    // When no Calibre custom column for word count is configured, this bulk-fetches
    // ao3_metadata.word_count values via the cached ao3WordCountCache, which
    // is bulk-fetched by AmbrosiaMetaDB and pushed in by LibrarySession.
    func ao3WordCounts(ids: [Int]) -> [Int: Int] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        return ao3WordCountCache.filter { idSet.contains($0.key) }
    }

    // MARK: - §2.2a: Bulk AO3 kudos fallback
    //
    // When no Calibre custom column for kudos is configured, this bulk-fetches
    // ao3_metadata.kudos_count values via the cached ao3KudosCache, which
    // is bulk-fetched by AmbrosiaMetaDB and pushed in by LibrarySession.
    // Mirrors ao3WordCounts(ids:) exactly.
    func ao3Kudos(ids: [Int]) -> [Int: Int] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        return ao3KudosCache.filter { idSet.contains($0.key) }
    }

    /// Bulk-fetch AO3 published/updated dates for a set of IDs from the
    /// cached `ao3DateCache` (see the AO3 metadata caches note above).
    /// Returns ISO-8601 date strings keyed by calibre ID. Missing entries = no AO3 metadata.
    func ao3Dates(ids: [Int]) -> [Int: (published: String?, updated: String?)] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        return ao3DateCache.filter { idSet.contains($0.key) }
    }

    /// Sort books by unified date (archive metadata dates with fallback to Calibre pubdate).
    /// Books with no date in either system sort last in both directions.
    func sortedByDate(
        books: [CalibreBook],
        field: SortField,
        ascending: Bool
    ) -> [CalibreBook] {
        let dates = ao3Dates(ids: books.map(\.id))
        let iso = ISO8601DateFormatter()
        return books.sorted { bookA, bookB in
            let dateA: String?
            let dateB: String?
            if field == .updated {
                dateA = dates[bookA.id]?.updated ?? dates[bookA.id]?.published ?? bookA.publishedDate.map { iso.string(from: $0) }
                dateB = dates[bookB.id]?.updated ?? dates[bookB.id]?.published ?? bookB.publishedDate.map { iso.string(from: $0) }
            } else {
                dateA = dates[bookA.id]?.published ?? bookA.publishedDate.map { iso.string(from: $0) }
                dateB = dates[bookB.id]?.published ?? bookB.publishedDate.map { iso.string(from: $0) }
            }
            switch (dateA, dateB) {
            case (nil, nil): return bookA.title < bookB.title
            case (nil, _):   return false
            case (_, nil):   return true
            case let (x?, y?): return ascending ? x < y : x > y
            }
        }
    }

    /// Sort books by an AO3 date field (ISO-8601 string, lexicographic order).
    /// Books with no AO3 metadata sort last in both directions.
    func sortedByAO3Date(
        books: [CalibreBook],
        keyPath: KeyPath<(published: String?, updated: String?), String?>,
        ascending: Bool
    ) -> [CalibreBook] {
        let dates = ao3Dates(ids: books.map(\.id))
        return books.sorted { bookA, bookB in
            let av = dates[bookA.id].flatMap { $0[keyPath: keyPath] }
            let bv = dates[bookB.id].flatMap { $0[keyPath: keyPath] }
            switch (av, bv) {
            case (nil, nil): return bookA.title < bookB.title
            case (nil, _):   return false
            case (_, nil):   return true
            case let (x?, y?): return ascending ? x < y : x > y
            }
        }
    }

    /// §2a fix (2): word-count sort, resolved entirely in Swift with D4 tie-breaking.
    func sortedByWordCount(books: [CalibreBook], ascending: Bool,
                           ao3WordCounts: [Int: Int]) -> [CalibreBook] {
        let valuesByID: [Int: Int]
        if let label = CustomColumnConfig.shared.wordCountLabel,
           let tbl = customColumnTableName(label: label) {
            valuesByID = bulkCustomColumnInts(table: tbl, ids: books.map(\.id))
        } else {
            valuesByID = ao3WordCounts
        }
        return books.sorted { bookA, bookB in
            let valA = valuesByID[bookA.id]
            let valB = valuesByID[bookB.id]
            switch (valA, valB) {
            case let (vA?, vB?):
                if vA != vB {
                    return ascending ? vA < vB : vA > vB
                }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
            let cmp = bookA.title.caseInsensitiveCompare(bookB.title)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return bookA.id < bookB.id
        }
    }

    /// Total-order comparator for numeric values with nil-last semantics and D4 tie-breaking (title ASC, then calibre_id ASC).
    private func compareNumericD4(
        first: (id: Int, val: Int?),
        second: (id: Int, val: Int?),
        titles: [Int: String],
        ascending: Bool
    ) -> Bool {
        switch (first.val, second.val) {
        case let (vA?, vB?):
            if vA != vB {
                return ascending ? vA < vB : vA > vB
            }
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            break
        }
        let titleA = titles[first.id] ?? ""
        let titleB = titles[second.id] ?? ""
        let cmp = titleA.caseInsensitiveCompare(titleB)
        if cmp != .orderedSame {
            return cmp == .orderedAscending
        }
        return first.id < second.id
    }

    /// Bulk-fetch just `title` for a set of IDs — analogous to `ao3WordCounts`/
    /// `bulkCustomColumnInts`, used where sorting needs every matched book's
    /// title but hydrating full `CalibreBook`s (authors/tags/comments) for
    /// the whole matched set, not just the final page, would be wasteful.
    func bulkTitles(ids: [Int]) -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        let sql = "SELECT id, title FROM books WHERE \(SQLIDList.clause(column: "id"))"
        guard let rows = try? db.prepare(sql, [SQLIDList.binding(ids)]).map({ $0 }) else { return [:] }
        var result: [Int: String] = [:]
        for row in rows {
            guard let id = (row[0] as? Int64).map(Int.init), let title = row[1] as? String else { continue }
            result[id] = title
        }
        return result
    }

    /// Bulk-fetch just the AO3 rating tag(s) attached to each of `ids`, keyed
    /// by calibre id — analogous to `bulkTitles`, used by
    /// `SeriesMatchExpansion.expand` so series-aware rating checks don't pay
    /// for a full `booksForIDs` hydration (authors/tags/comments) just to
    /// read one tag. A book normally has zero or one rating tag; the array
    /// shape is defensive, not an expectation of multiples. Chunked at the
    /// same 900-id boundary as `tagsInternal(for:)`, since this is the same
    /// `books_tags_link`/`tags` join with an additional bound rating-name
    /// list on top, and unchunked would risk exceeding SQLite's bound
    /// parameter limit for large expanded-series ID sets.
    func bulkRatingTags(ids: [Int]) -> [Int: [String]] {
        guard !ids.isEmpty else { return [:] }
        let ratingValues = AO3Rating.allCases.map(\.rawValue)
        let ratingPlaceholders = ratingValues.map { _ in "?" }.joined(separator: ",")
        var result: [Int: [String]] = [:]
        let chunkSize = 900
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[chunkStart..<min(chunkStart + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT btl.book, t.name FROM books_tags_link btl
                JOIN tags t ON t.id = btl.tag
                WHERE btl.book IN (\(placeholders))
                  AND t.name IN (\(ratingPlaceholders))
                """
            let args = chunk.map { $0 as Binding? } + ratingValues.map { $0 as Binding? }
            guard let rows = try? db.prepare(sql, args).map({ $0 }) else { continue }
            for row in rows {
                guard let id = (row[0] as? Int64).map(Int.init), let tag = row[1] as? String else { continue }
                result[id, default: []].append(tag)
            }
        }
        return result
    }

    /// The filter/visibility inputs shared by every `*SortedPage` function
    /// below (word count, kudos, group-aware title, random, relevance).
    struct PageQuery {
        var query: SearchQuery
        var filter: FilterExpression?
        var restrictIDs: [Int]?
        var visibility: LibraryVisibilityPolicy = .allowAll
        var filterTagExpansions: [String: [String]] = [:]
        var visibilityVersion: Int = 0
        var pinnedCollectionVersion: Int = 0
        var metaDB: AmbrosiaMetaDB?
        var rankedIDs: [Int]?
        var relevanceTargets: TagRelevanceTargets = .init()
        var rankedIDsAreOrdered: Bool = true
        var queryDigest: String

        init(
            query: SearchQuery,
            filter: FilterExpression? = nil,
            restrictIDs: [Int]? = nil,
            visibility: LibraryVisibilityPolicy = .allowAll,
            filterTagExpansions: [String: [String]] = [:],
            visibilityVersion: Int = 0,
            pinnedCollectionVersion: Int = 0,
            metaDB: AmbrosiaMetaDB? = nil,
            rankedIDs: [Int]? = nil,
            relevanceTargets: TagRelevanceTargets = .init(),
            rankedIDsAreOrdered: Bool = true,
            queryDigest: String? = nil
        ) {
            self.query = query
            self.filter = filter
            self.restrictIDs = restrictIDs
            self.visibility = visibility
            self.filterTagExpansions = filterTagExpansions
            self.visibilityVersion = visibilityVersion
            self.pinnedCollectionVersion = pinnedCollectionVersion
            self.metaDB = metaDB
            self.rankedIDs = rankedIDs
            self.relevanceTargets = relevanceTargets
            self.rankedIDsAreOrdered = rankedIDsAreOrdered
            self.queryDigest = queryDigest ?? QueryDigestBuilder.digest(
                query: query,
                filter: filter,
                restrictIDs: restrictIDs,
                filterTagExpansions: filterTagExpansions,
                rankedIDs: rankedIDs,
                relevanceTargets: relevanceTargets,
                rankedIDsAreOrdered: rankedIDsAreOrdered
            )
        }
    }

    enum SortKind: Sendable {
        case random
        case relevance
        case wordCount
        case kudos
        case groupAwareTitle
    }

    private func makePageCacheKey(
        pageQuery: PageQuery,
        sortField: SortField,
        ascending: Bool,
        offset: Int,
        limit: Int
    ) -> PageCacheKey {
        PageCacheKey(
            querySignature: LibraryFilterDebug.summary(query: pageQuery.query),
            filterSignature: pageQuery.filter.map { LibraryFilterDebug.summary(expression: $0) } ?? "",
            tagExpansionsDigest: tagExpansionsDigest(pageQuery.filterTagExpansions),
            visibilityVersion: pageQuery.visibilityVersion,
            pinnedCollectionVersion: pageQuery.pinnedCollectionVersion,
            visibilitySignature: pageQuery.visibility.cacheSignature,
            sortField: sortField,
            ascending: ascending,
            randomSeed: randomSeed,
            queryDigest: pageQuery.queryDigest,
            offset: offset,
            limit: limit
        )
    }

    private func materializedSortedIDs(
        key: SortedIDsCacheKey,
        kind: SortKind,
        pageQuery: PageQuery,
        ascending: Bool
    ) async -> [Int] {
        if let cached = sortedIDsCache.get(key) {
            LaunchSignposts.event("sortedIDsCache.hit")
            return cached
        }
        if let running = sortedIDsInFlight[key] {
            LaunchSignposts.event("sortedIDsInFlight.join")
            return await running.value
        }
        let generation = sortedIDsGeneration
        let task = Task { await self.computeSortedIDs(kind: kind, pageQuery: pageQuery, ascending: ascending) }
        sortedIDsInFlight[key] = task
        let ids = await task.value
        if sortedIDsGeneration == generation {
            sortedIDsInFlight[key] = nil
            sortedIDsCache.set(ids, for: key)
        }
        return ids
    }

    private func computeSortedIDs(
        kind: SortKind,
        pageQuery: PageQuery,
        ascending: Bool
    ) async -> [Int] {
        sortedIDsComputeCount += 1
        LaunchSignposts.event("sortedIDsCache.compute")
        switch kind {
        case .random:
            return await computeRandomSortedIDs(ascending: ascending, pageQuery)
        case .relevance:
            return await computeRelevanceSortedIDs(ascending: ascending, pageQuery)
        case .wordCount:
            return await computeWordCountSortedIDs(ascending: ascending, pageQuery)
        case .kudos:
            return await computeKudosSortedIDs(ascending: ascending, pageQuery)
        case .groupAwareTitle:
            return await computeGroupAwareTitleSortedIDs(ascending: ascending, pageQuery)
        }
    }

    /// Fetches the full matching set, sorts it by word count in memory with D4 tie-breaking,
    /// caching the sorted ID array so subsequent page requests are served without re-querying.
    func wordCountSortedPage(offset: Int, limit: Int, ascending: Bool,
                             _ pageQuery: PageQuery) async -> (page: [CalibreBook], hasMore: Bool) {
        let cacheKey = makePageCacheKey(
            pageQuery: pageQuery,
            sortField: .wordCount,
            ascending: ascending,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] { LaunchSignposts.event("pageCache.hit"); return cached }
        let generation = sortedIDsGeneration

        let sortedIDs = await materializedSortedIDs(
            key: cacheKey.sortedKey,
            kind: .wordCount,
            pageQuery: pageQuery,
            ascending: ascending
        )
        let start = min(offset, sortedIDs.count)
        let end   = min(offset + limit, sortedIDs.count)
        guard start < end else {
            if sortedIDsGeneration == generation {
                pageCache.set(([], false), for: cacheKey)
            }
            return ([], false)
        }
        let pageIDs = Array(sortedIDs[start..<end])
        let page = orderedBooks(for: pageIDs)
        let result = (page, end < sortedIDs.count)
        if sortedIDsGeneration == generation {
            pageCache.set(result, for: cacheKey)
        }
        return result
    }

    private func computeWordCountSortedIDs(ascending: Bool, _ pageQuery: PageQuery) async -> [Int] {
        let rawMatchedIDs = fetchAllMatchingIDs(
            query: pageQuery.query,
            filter: pageQuery.filter,
            restrictIDs: pageQuery.restrictIDs,
            filterTagExpansions: pageQuery.filterTagExpansions
        )
        let matchedIDs = await SeriesMatchExpansion.expand(
            matchedIDs: rawMatchedIDs,
            shouldGroupSeriesRows: pageQuery.visibility.shouldGroupSeriesRows,
            filter: pageQuery.filter,
            library: self,
            metaDB: pageQuery.metaDB
        )
        let allIDs = pageQuery.visibility.filter(matchedIDs)

        let wordCounts: [Int: Int]
        if let label = CustomColumnConfig.shared.wordCountLabel,
           let tbl = customColumnTableName(label: label) {
            wordCounts = bulkCustomColumnInts(table: tbl, ids: allIDs)
        } else {
            wordCounts = ao3WordCounts(ids: allIDs)
        }

        let titles = bulkTitles(ids: allIDs)
        return allIDs.sorted { idA, idB in
            compareNumericD4(
                first: (idA, wordCounts[idA]),
                second: (idB, wordCounts[idB]),
                titles: titles,
                ascending: ascending
            )
        }
    }

    /// Fetches the full matching set, sorts it by kudos in memory with D4 tie-breaking,
    /// caching the sorted ID array so subsequent page requests are served without re-querying.
    func kudosSortedPage(offset: Int, limit: Int, ascending: Bool,
                         _ pageQuery: PageQuery) async -> (page: [CalibreBook], hasMore: Bool) {
        let cacheKey = makePageCacheKey(
            pageQuery: pageQuery,
            sortField: .kudos,
            ascending: ascending,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] { LaunchSignposts.event("pageCache.hit"); return cached }
        let generation = sortedIDsGeneration

        let sortedIDs = await materializedSortedIDs(
            key: cacheKey.sortedKey,
            kind: .kudos,
            pageQuery: pageQuery,
            ascending: ascending
        )
        let start = min(offset, sortedIDs.count)
        let end   = min(offset + limit, sortedIDs.count)
        guard start < end else {
            if sortedIDsGeneration == generation {
                pageCache.set(([], false), for: cacheKey)
            }
            return ([], false)
        }
        let pageIDs = Array(sortedIDs[start..<end])
        let page = orderedBooks(for: pageIDs)
        let result = (page, end < sortedIDs.count)
        if sortedIDsGeneration == generation {
            pageCache.set(result, for: cacheKey)
        }
        return result
    }

    private func computeKudosSortedIDs(ascending: Bool, _ pageQuery: PageQuery) async -> [Int] {
        let rawMatchedIDs = fetchAllMatchingIDs(
            query: pageQuery.query,
            filter: pageQuery.filter,
            restrictIDs: pageQuery.restrictIDs,
            filterTagExpansions: pageQuery.filterTagExpansions
        )
        let matchedIDs = await SeriesMatchExpansion.expand(
            matchedIDs: rawMatchedIDs,
            shouldGroupSeriesRows: pageQuery.visibility.shouldGroupSeriesRows,
            filter: pageQuery.filter,
            library: self,
            metaDB: pageQuery.metaDB
        )
        let allIDs = pageQuery.visibility.filter(matchedIDs)

        let kudos: [Int: Int]
        if let label = CustomColumnConfig.shared.kudosLabel,
           let tbl = customColumnTableName(label: label) {
            kudos = bulkCustomColumnInts(table: tbl, ids: allIDs)
        } else {
            kudos = ao3Kudos(ids: allIDs)
        }

        let titles = bulkTitles(ids: allIDs)
        return allIDs.sorted { idA, idB in
            compareNumericD4(
                first: (idA, kudos[idA]),
                second: (idB, kudos[idB]),
                titles: titles,
                ascending: ascending
            )
        }
    }

    /// Group-aware title-sorted page. Caches the full sorted ID array so
    /// subsequent page requests are served without re-querying.
    func groupAwareTitleSortedPage(offset: Int, limit: Int, ascending: Bool,
                                   _ pageQuery: PageQuery) async -> (page: [CalibreBook], hasMore: Bool) {
        let cacheKey = makePageCacheKey(
            pageQuery: pageQuery,
            sortField: .title,
            ascending: ascending,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] { LaunchSignposts.event("pageCache.hit"); return cached }
        let generation = sortedIDsGeneration

        let sortedIDs = await materializedSortedIDs(
            key: cacheKey.sortedKey,
            kind: .groupAwareTitle,
            pageQuery: pageQuery,
            ascending: ascending
        )
        let start = min(offset, sortedIDs.count)
        let end   = min(offset + limit, sortedIDs.count)
        guard start < end else {
            if sortedIDsGeneration == generation {
                pageCache.set(([], false), for: cacheKey)
            }
            return ([], false)
        }
        let pageIDs = Array(sortedIDs[start..<end])
        let page = orderedBooks(for: pageIDs)
        let result = (page, end < sortedIDs.count)
        if sortedIDsGeneration == generation {
            pageCache.set(result, for: cacheKey)
        }
        return result
    }

    /// Materialize every matching id, apply series expansion and visibility,
    /// and sort.
    private func computeGroupAwareTitleSortedIDs(ascending: Bool, _ pageQuery: PageQuery) async -> [Int] {
        let query = pageQuery.query
        let filter = pageQuery.filter
        let restrictIDs = pageQuery.restrictIDs
        let visibility = pageQuery.visibility
        let filterTagExpansions = pageQuery.filterTagExpansions
        let metaDB = pageQuery.metaDB

        let computeSignpost = LaunchSignposts.begin("groupAwareTitleSortedPage.compute")
        defer { LaunchSignposts.end("groupAwareTitleSortedPage.compute", computeSignpost) }
        let t0 = LibraryFilterDebug.now()
        let rawMatchedIDs = fetchAllMatchingIDs(query: query, filter: filter, restrictIDs: restrictIDs,
                                                filterTagExpansions: filterTagExpansions)
        let matchedIDs = await SeriesMatchExpansion.expand(
            matchedIDs: rawMatchedIDs,
            shouldGroupSeriesRows: visibility.shouldGroupSeriesRows,
            filter: filter,
            library: self,
            metaDB: metaDB
        )
        let allIDs = visibility.filter(matchedIDs)
        let tFiltered = LibraryFilterDebug.elapsedMS(since: t0)

        let seriesNames: [Int: String]
        if let metaDB {
            seriesNames = (try? await metaDB.qualifyingSeriesNames(for: allIDs)) ?? [:]
        } else {
            seriesNames = [:]
        }
        let tSeriesNames = LibraryFilterDebug.elapsedMS(since: t0)
        let titles = bulkTitles(ids: allIDs)
        let tTitles = LibraryFilterDebug.elapsedMS(since: t0)
        let sortedIDs = GroupAwareSorter.sort(ids: allIDs, seriesNames: seriesNames,
                                              titles: titles, ascending: ascending)

        LibraryFilterDebug.log("groupAwareTitleSortedPage.stages", [
            "matched": rawMatchedIDs.count,
            "visible": allIDs.count,
            "filteredMS(cumulative)": tFiltered,
            "seriesNamesMS(cumulative)": tSeriesNames,
            "titlesMS(cumulative)": tTitles,
            "sortedMS(cumulative)": LibraryFilterDebug.elapsedMS(since: t0)
        ])
        return sortedIDs
    }

    /// Group-aware total: the count of matching books that would actually be
    /// shown once skip/series-grouping/AO3-publisher/anthology visibility is
    /// applied — not the raw SQL row count `fetchAllMatchingIDs` alone would
    /// give (which double-counts collapsed series members and ignores the
    /// publisher/anthology toggles). Used for "Page X of Y" in grouped mode.
    func visibleBookCount(_ pageQuery: PageQuery) async -> Int {
        let query = pageQuery.query
        let filter = pageQuery.filter
        let restrictIDs = pageQuery.restrictIDs
        let visibility = pageQuery.visibility
        let filterTagExpansions = pageQuery.filterTagExpansions
        let visibilityVersion = pageQuery.visibilityVersion
        let metaDB = pageQuery.metaDB
        let cacheKey = GroupAwareCountCacheKey(
            querySignature: LibraryFilterDebug.summary(query: query),
            filterSignature: filter.map { LibraryFilterDebug.summary(expression: $0) } ?? "",
            tagExpansionsDigest: tagExpansionsDigest(filterTagExpansions),
            visibilityVersion: visibilityVersion,
            pinnedCollectionVersion: pageQuery.pinnedCollectionVersion,
            showSkippedCollection: visibility.showSkippedCollection,
            hideNonAO3PublisherBooks: visibility.hideNonAO3PublisherBooks,
            hideAnthologyBooks: visibility.hideAnthologyBooks,
            hideDuplicateBooks: visibility.hideDuplicateBooks,
            shouldGroupSeriesRows: visibility.shouldGroupSeriesRows
        )
        if let cached = groupAwareCountCache[cacheKey] { return cached }
        let rawMatchedIDs = fetchAllMatchingIDs(query: query, filter: filter, restrictIDs: restrictIDs,
                                                filterTagExpansions: filterTagExpansions)
        let matchedIDs = await SeriesMatchExpansion.expand(
            matchedIDs: rawMatchedIDs,
            shouldGroupSeriesRows: visibility.shouldGroupSeriesRows,
            filter: filter,
            library: self,
            metaDB: metaDB
        )
        let count = visibility.filter(matchedIDs).count
        groupAwareCountCache.set(count, for: cacheKey)
        return count
    }

    /// Random-sorted page, caching the shuffled ID list per seed so
    /// subsequent page requests preserve the shuffle without reshuffling.
    func randomSortedPage(offset: Int, limit: Int,
                          _ pageQuery: PageQuery) async -> (page: [CalibreBook], hasMore: Bool) {
        let cacheKey = makePageCacheKey(
            pageQuery: pageQuery,
            sortField: .random,
            ascending: true,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] { LaunchSignposts.event("pageCache.hit"); return cached }
        let generation = sortedIDsGeneration

        let sortedIDs = await materializedSortedIDs(
            key: cacheKey.sortedKey,
            kind: .random,
            pageQuery: pageQuery,
            ascending: true
        )
        let start = min(offset, sortedIDs.count)
        let end   = min(offset + limit, sortedIDs.count)
        guard start < end else {
            if sortedIDsGeneration == generation {
                pageCache.set(([], false), for: cacheKey)
            }
            return ([], false)
        }
        let pageIDs = Array(sortedIDs[start..<end])
        let page = orderedBooks(for: pageIDs)
        let result = (page, end < sortedIDs.count)
        if sortedIDsGeneration == generation {
            pageCache.set(result, for: cacheKey)
        }
        return result
    }

    private func computeRandomSortedIDs(ascending: Bool, _ pageQuery: PageQuery) async -> [Int] {
        let rawMatchedIDs = fetchAllMatchingIDs(
            query: pageQuery.query,
            filter: pageQuery.filter,
            restrictIDs: pageQuery.restrictIDs,
            filterTagExpansions: pageQuery.filterTagExpansions
        )
        let matchedIDs = await SeriesMatchExpansion.expand(
            matchedIDs: rawMatchedIDs,
            shouldGroupSeriesRows: pageQuery.visibility.shouldGroupSeriesRows,
            filter: pageQuery.filter,
            library: self,
            metaDB: pageQuery.metaDB
        )
        let allIDs = pageQuery.visibility.filter(matchedIDs)
        return sortedRandomly(allIDs)
    }

    /// Relevance-sorted page for search and filter hits, caching the ranked ID array.
    func relevanceSortedPage(
        offset: Int,
        limit: Int,
        ascending: Bool,
        _ pageQuery: PageQuery
    ) async -> (page: [CalibreBook], hasMore: Bool) {
        let cacheKey = makePageCacheKey(
            pageQuery: pageQuery,
            sortField: .relevance,
            ascending: ascending,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] { LaunchSignposts.event("pageCache.hit"); return cached }
        let generation = sortedIDsGeneration

        let sortedIDs = await materializedSortedIDs(
            key: cacheKey.sortedKey,
            kind: .relevance,
            pageQuery: pageQuery,
            ascending: ascending
        )
        let start = min(offset, sortedIDs.count)
        let end   = min(offset + limit, sortedIDs.count)
        guard start < end else {
            if sortedIDsGeneration == generation {
                pageCache.set(([], false), for: cacheKey)
            }
            return ([], false)
        }
        let pageIDs = Array(sortedIDs[start..<end])
        let page = orderedBooks(for: pageIDs)
        let result = (page, end < sortedIDs.count)
        if sortedIDsGeneration == generation {
            pageCache.set(result, for: cacheKey)
        }
        return result
    }

    private func computeRelevanceSortedIDs(ascending: Bool, _ pageQuery: PageQuery) async -> [Int] {
        let rawMatchedIDs = fetchAllMatchingIDs(
            query: pageQuery.query,
            filter: pageQuery.filter,
            restrictIDs: pageQuery.restrictIDs,
            filterTagExpansions: pageQuery.filterTagExpansions
        )
        let matchedIDs = await SeriesMatchExpansion.expand(
            matchedIDs: rawMatchedIDs,
            shouldGroupSeriesRows: pageQuery.visibility.shouldGroupSeriesRows,
            filter: pageQuery.filter,
            library: self,
            metaDB: pageQuery.metaDB
        )
        let allIDs = pageQuery.visibility.filter(matchedIDs)

        let targets = !pageQuery.relevanceTargets.isEmpty
            ? pageQuery.relevanceTargets
            : TagRelevanceTargets.make(
                expression: pageQuery.filter,
                query: pageQuery.query,
                expansions: pageQuery.filterTagExpansions
            )
        let exactTargets = targets.exact
        let containsTargets = targets.contains

        var posMap: [Int: TagPosition]?
        if !exactTargets.isEmpty || !containsTargets.isEmpty, let metaDB = pageQuery.metaDB {
            posMap = await metaDB.firstListedPositions(
                exactTargets: exactTargets,
                containsTargets: containsTargets,
                bookIDs: allIDs
            )
            guard !Task.isCancelled else { return [] }
        }

        let candidateRanked = pageQuery.rankedIDs ?? pageQuery.query.ftsMatchedIDs
        let rankMap: [Int: Int]?
        if pageQuery.rankedIDsAreOrdered, let ranked = candidateRanked, !ranked.isEmpty {
            rankMap = Dictionary(ranked.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            rankMap = nil
        }

        if rankMap == nil && (posMap?.isEmpty ?? true) {
            return allIDs
        }

        let idIndexMap = Dictionary(allIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let tieBreak: (Int, Int) -> Bool = { idA, idB in
            let idxA = idIndexMap[idA] ?? Int.max
            let idxB = idIndexMap[idB] ?? Int.max
            if idxA != idxB {
                return idxA < idxB
            }
            return idA < idB
        }

        return allIDs.sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: rankMap,
                posMap: posMap,
                ascending: ascending,
                tieBreak: tieBreak
            )
        }
    }

    // MARK: - §1: fetchAllMatchingIDs (lightweight — IDs only, no hydration)
    //
    // Used by wordCountSortedPage to get the full matching set without the cost of
    // hydrating authors, tags, and comments for every book. The authors LEFT JOIN is
    // kept because whereClause may emit author conditions; tags and comments joins
    // are omitted (never referenced in WHERE by fetchBooksInternal).

    func fetchAllMatchingIDs(
        query: SearchQuery,
        filter: FilterExpression?,
        restrictIDs: [Int]?,
        filterTagExpansions: [String: [String]] = [:]
    ) -> [Int] {
        var conditions: [String] = []
        var args: [Binding?] = []

        if let ids = restrictIDs {
            if ids.isEmpty {
                conditions.append("0 = 1")
            } else {
                conditions.append(SQLIDList.clause(column: "b.id"))
                args.append(SQLIDList.binding(ids))
            }
        }
        let (qClause, qArgs) = whereClause(for: query)
        if !qClause.isEmpty {
            conditions.append(qClause)
            args.append(contentsOf: qArgs)
        }
        if let filter {
            if let (fClause, fArgs) = sqlFilterClause(for: filter, tagExpansions: filterTagExpansions) {
                conditions.append(fClause)
                args.append(contentsOf: fArgs)
            } else if filter.hasCompleteRules {
                conditions.append("0 = 1")
            }
        }
        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        // §perf: Only join `comments` when a filter rule references the comment field.
        let needsCommentJoin = filter?.groups.flatMap(\.completeRules)
            .contains { $0.field == .comment } == true
        let commentJoin = needsCommentJoin ? "LEFT JOIN comments c ON c.book = b.id" : ""
        let groupBy = needsCommentJoin ? "GROUP BY b.id" : ""
        let sql = """
            SELECT b.id FROM books b
            \(commentJoin)
            \(whereSQL)
            \(groupBy)
            ORDER BY b.title ASC, b.id ASC
            """
        guard let rows = try? db.prepare(sql, args).map({ $0 }) else { return [] }
        return rows.compactMap { ($0[0] as? Int64).map(Int.init) }
    }

    // MARK: - §1: fetchAllMatchingBooks
    //
    // Fetches every book matching the current search query + filter result without
    // pagination. Used exclusively by ExportManager. Returns at most 50 000 books
    // to prevent runaway memory use; the UI shows a warning if the cap is hit.
    //
    // This path must NOT re-run FilterBuilder — the caller already has a FilterResult
    // from the normal paged flow and passes the resolved calibreIDs directly.

    static let exportCap = 50_000

    /// Fetch all matching books (no pagination) for export.
    /// - Parameter ids: The pre-resolved calibre IDs from the active FilterResult (or nil for unfiltered).
    /// - Parameter query: The active search query for additional SQL-level narrowing.
    /// - Parameter filter: The active FilterExpression for SQL-backed filters (e.g. NOT-tag rules)
    ///   whose matches aren't pre-resolved into an ID list. Pass nil when `ids` already fully
    ///   represents the active filter (the explicit-IDs path).
    /// - Parameter sort / ascending: Passed through to order the CSV consistently with the UI.
    func fetchAllMatchingBooks(ids: [Int]?,
                               query: SearchQuery,
                               filter: FilterExpression? = nil,
                               sort: SortField,
                               ascending: Bool) -> [CalibreBook] {
        do {
            let cap = Self.exportCap
            let rows = try fetchBooksInternal(
                offset: 0, limit: cap + 1,
                sort: sort, ascending: ascending,
                query: query, filter: filter,
                restrictIDs: ids
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try authorsInternal(for: fetchedIDs)
            let tagsMap     = try tagsInternal(for: fetchedIDs)
            let commentsMap = try commentsInternal(for: fetchedIDs)
            return rows.prefix(cap).map { book in
                var enrichedBook = book
                enrichedBook.authors = authorsMap[book.id] ?? []
                enrichedBook.tags    = tagsMap[book.id] ?? []
                enrichedBook.comment = commentsMap[book.id]
                return enrichedBook
            }
        } catch {
            #if DEBUG
            print("[CalibreLibrary] fetchAllMatchingBooks error: \(error)")
            #endif
            return []
        }
    }

    // MARK: - Core fetch (search/filter path)

    func books(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: []),
        filter: FilterExpression? = nil,
        filterTagExpansions: [String: [String]] = [:],
        visibilityVersion: Int = 0,
        pinnedCollectionVersion: Int = 0
    ) -> [CalibreBook] {
        // §Phase3: this is the hot path hit on every page load/switch when no
        // explicit ID set is active (the scenario the page cache targets —
        // identical filter/sort/page on List vs Email used to both hit SQL).
        // Cache is keyed on the page contents only (offset/limit), NOT on
        // hasMore, since this overload has no "more pages" concept of its own.
        let cacheKey = PageCacheKey(
            querySignature: LibraryFilterDebug.summary(query: query),
            filterSignature: filter.map { LibraryFilterDebug.summary(expression: $0) } ?? "",
            tagExpansionsDigest: tagExpansionsDigest(filterTagExpansions),
            visibilityVersion: visibilityVersion,
            pinnedCollectionVersion: pinnedCollectionVersion,
            visibilitySignature: "",   // caller (the view) applies visibility to the raw page
            sortField: sort,
            ascending: ascending,
            randomSeed: randomSeed,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] {
            LaunchSignposts.event("pageCache.hit")
            LibraryFilterDebug.log("books.cacheHit", ["rows": cached.page.count])
            return cached.page
        }
        let generation = sortedIDsGeneration
        let start = LibraryFilterDebug.now()
        do {
            let rows = try fetchBooksInternal(
                offset: offset, limit: limit,
                sort: sort, ascending: ascending,
                query: query, filter: filter,
                restrictIDs: nil,
                filterTagExpansions: filterTagExpansions
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try authorsInternal(for: fetchedIDs)
            let tagsMap     = try tagsInternal(for: fetchedIDs)
            let commentsMap = try commentsInternal(for: fetchedIDs)
            LibraryFilterDebug.log("books.end", [
                "rows": rows.count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: start)
            ])
            var result = rows.map { book in
                var enrichedBook = book
                enrichedBook.authors = authorsMap[book.id] ?? []
                enrichedBook.tags    = tagsMap[book.id] ?? []
                enrichedBook.comment = commentsMap[book.id]
                return enrichedBook
            }
            switch sort {
            case .published, .updated:
                result = sortedByDate(books: result, field: sort, ascending: ascending)
            default:
                break
            }
            // hasMore is not knowable from this overload alone (callers infer it
            // from rows.count vs the limit they passed); store false as a filler,
            // it is never read back — only `.page` is used by this overload's callers.
            if sortedIDsGeneration == generation {
                pageCache.set((result, false), for: cacheKey)
            }
            return result
        } catch {
            #if DEBUG
            print("[CalibreLibrary] books error: \(error)")
            #endif
            return []
        }
    }

    // MARK: - Internal fetch implementation

    func fetchBooksInternal(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery,
        filter: FilterExpression? = nil,
        restrictIDs: [Int]? = nil,
        filterTagExpansions: [String: [String]] = [:],
        skipSort: Bool = false
    ) throws -> [CalibreBook] {
        let direction = ascending ? "ASC" : "DESC"
        // §6 fix: random sort falls back to title in SQL; caller reshuffles post-fetch.
        let orderBy = skipSort ? "b.id ASC" : orderByClause(sort: sort, direction: direction)

        // §6 + §2a: Add kudos LEFT JOIN only when sorting by kudos. (Word-count's
        // wcJoin was removed — word-count sort is now resolved in Swift; see
        // wordCountSortedPage(...) / orderByClause(.wordCount) above.)
        let kJoin: String = {
            guard sort == .kudos, let tbl = kudosCustomColumnTable() else { return "" }
            return "LEFT JOIN \(tbl) k ON k.book = b.id"
        }()

        // Pass 3 item 5: bal / a joins only when sorting by author.
        let authorJoin: String = {
            guard sort == .author else { return "" }
            return """
            LEFT JOIN books_authors_link bal ON bal.book = b.id
            LEFT JOIN authors a ON a.id = bal.author
            """
        }()

        // §perf: Only join `comments` when a filter rule references the comment field.
        // `comments` stores large HTML blobs; joining it unconditionally forces SQLite to
        // walk the table for every query even though the comment text is never read from
        // the main row (it is bulk-fetched separately by commentsInternal(for:)).
        let needsCommentJoin = filter?.groups.flatMap(\.completeRules)
            .contains { $0.field == .comment } == true
        let commentJoin = needsCommentJoin ? "LEFT JOIN comments c ON c.book = b.id" : ""

        var conditions: [String] = []
        var args: [Binding?] = []

        // Restrict to explicit ID set (FilterResult path)
        if let ids = restrictIDs {
            if ids.isEmpty {
                conditions.append("0 = 1")
            } else {
                conditions.append(SQLIDList.clause(column: "b.id"))
                args.append(SQLIDList.binding(ids))
            }
        }

        let (qClause, qArgs) = whereClause(for: query)
        if !qClause.isEmpty {
            conditions.append(qClause)
            args.append(contentsOf: qArgs)
        }
        if let filter {
            if let (fClause, fArgs) = sqlFilterClause(for: filter, tagExpansions: filterTagExpansions) {
                conditions.append(fClause)
                args.append(contentsOf: fArgs)
            } else if filter.hasCompleteRules {
                conditions.append("0 = 1")
            }
        }

        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        // §perf: DROP `SELECT DISTINCT` — `GROUP BY b.id` already deduplicates. DISTINCT
        // on top of GROUP BY adds a redundant sort+hash step that costs ~30 % of query time
        // on large libraries with multi-author or multi-series books.
        let sql = """
            SELECT b.id, b.title, b.path, b.pubdate, s.name, b.series_index, p.name
            FROM books b
            \(authorJoin)
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            LEFT JOIN books_publishers_link bpl ON bpl.book = b.id
            LEFT JOIN publishers p ON p.id = bpl.publisher
            \(commentJoin)
            \(kJoin)
            \(whereSQL)
            GROUP BY b.id
            ORDER BY \(orderBy)
            LIMIT ? OFFSET ?
            """
        args.append(contentsOf: [limit as Binding?, offset as Binding?])
        return try _mapBookRows(db.prepare(sql, args).map { $0 })
    }

    private func _mapBookRows(_ rows: [[Binding?]]) throws -> [CalibreBook] {
        rows.compactMap { row -> CalibreBook? in
            guard let idBind    = row[0] as? Int64,
                  let title     = row[1] as? String,
                  let path      = row[2] as? String else { return nil }
            return CalibreBook(
                id: Int(idBind),
                title: title,
                series: row[4] as? String,
                seriesIndex: row[5] as? Double,
                wordCount: nil,  // populated by bulk custom-column fetch in caller
                kudos: nil,
                publishedDate: (row[3] as? String).flatMap(parseDate),
                publisher: row[6] as? String,
                relativePath: path
            )
        }
    }

    /// Fetch from an explicit ID set with optional additional SearchQuery filtering.
    ///
    /// `context` is a short caller label (e.g. "feed:collection/<id>",
    /// "ui:libraryRootView") attached to the `books.page.end` debug log below.
    /// It exists because this method is called concurrently from unrelated
    /// subsystems that all contend for the same SQLite connection — the feed
    /// server and the app's own UI browsing chief among them — and without it
    /// a slow `books.page.end` line can't be attributed to its caller from the
    /// log alone.
    func books(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: []),
        context: String = "unknown"
    ) -> [CalibreBook] {
        let start = LibraryFilterDebug.now()
        do {
            let rows = try fetchBooksQueryIDsInternal(
                ids: ids, offset: offset, limit: limit,
                sort: sort, ascending: ascending, query: query)
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try authorsInternal(for: fetchedIDs)
            let tagsMap     = try tagsInternal(for: fetchedIDs)
            let commentsMap = try commentsInternal(for: fetchedIDs)
            var books = rows.map { book in
                var enrichedBook = book
                enrichedBook.authors = authorsMap[book.id] ?? []
                enrichedBook.tags    = tagsMap[book.id] ?? []
                enrichedBook.comment = commentsMap[book.id]
                return enrichedBook
            }
            switch sort {
            case .published, .updated:
                books = sortedByDate(books: books, field: sort, ascending: ascending)
            default:
                break
            }
            LibraryFilterDebug.log("books.page.end", [
                "context": context,
                "mode": ids == nil ? "unfilteredIDs" : "explicitIDs",
                "candidateIDs": ids?.count,
                "offset": offset,
                "limit": limit,
                "rows": books.count,
                "query": LibraryFilterDebug.summary(query: query),
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: start)
            ])
            return books
        } catch {
            #if DEBUG
            print("[CalibreLibrary] books(ids:query:) error: \(error)")
            #endif
            return []
        }
    }

    private func hydratedBooks(for ids: [Int], skipSort: Bool = false) -> [CalibreBook] {
        guard !ids.isEmpty else { return [] }
        do {
            let rows = try fetchBooksQueryIDsInternal(
                ids: ids,
                offset: 0,
                limit: max(ids.count, 1),
                sort: .title,
                ascending: true,
                query: SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: []),
                skipSort: skipSort
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap = try authorsInternal(for: fetchedIDs)
            let tagsMap = try tagsInternal(for: fetchedIDs)
            let commentsMap = try commentsInternal(for: fetchedIDs)
            return rows.map { book in
                var enrichedBook = book
                enrichedBook.authors = authorsMap[book.id] ?? []
                enrichedBook.tags = tagsMap[book.id] ?? []
                enrichedBook.comment = commentsMap[book.id]
                return enrichedBook
            }
        } catch {
            #if DEBUG
            print("[CalibreLibrary] booksForIDs error: \(error)")
            #endif
            return []
        }
    }

    /// Hydrates Calibre books for the given IDs, retaining historical SQL title ordering.
    /// Used by non-page callers that index results or expect alphabetical title order.
    func booksForIDs(_ ids: [Int]) -> [CalibreBook] {
        hydratedBooks(for: ids, skipSort: false)
    }

    /// Hydrates Calibre books strictly preserving the input `ids` sequence.
    /// Duplicate IDs yield a single entry (first occurrence). Missing IDs are dropped silently.
    func orderedBooks(for ids: [Int]) -> [CalibreBook] {
        guard !ids.isEmpty else { return [] }
        let books = hydratedBooks(for: ids, skipSort: true)
        var bookMap: [Int: CalibreBook] = [:]
        for book in books {
            bookMap[book.id] = book
        }
        var seen = Set<Int>()
        var result: [CalibreBook] = []
        for id in ids {
            if seen.insert(id).inserted, let book = bookMap[id] {
                result.append(book)
            }
        }
        return result
    }

    private func fetchBooksQueryIDsInternal(
        ids: [Int]? = nil,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery,
        skipSort: Bool = false
    ) throws -> [CalibreBook] {
        try fetchBooksInternal(
            offset: offset, limit: limit,
            sort: sort, ascending: ascending,
            query: query, filter: nil,
            restrictIDs: ids,
            skipSort: skipSort
        )
    }

    // MARK: - Bulk metadata helpers

    internal func authorsInternal(for ids: [Int]) throws -> [Int: [String]] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int: [String]] = [:]
        // SQLite's default SQLITE_MAX_VARIABLE_NUMBER is 999. Exceeding it while
        // iterating results crashes via `try!` in SQLite.swift's FailableIterator.
        // Chunk to stay safely under that limit regardless of how many IDs arrive.
        let chunkSize = 900
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[chunkStart..<min(chunkStart + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT bal.book, a.name FROM books_authors_link bal
                JOIN authors a ON a.id = bal.author
                WHERE bal.book IN (\(placeholders))
                ORDER BY bal.book, a.id
                """
            let args = chunk.map { $0 as Binding? }
            for row in try db.prepare(sql, args).map({ $0 }) {
                guard let cidBind = row[0] as? Int64,
                      let name   = row[1] as? String else { continue }
                let cid = Int(cidBind)
                result[cid, default: []].append(name)
            }
        }
        return result
    }

    internal func tagsInternal(for ids: [Int]) throws -> [Int: [String]] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int: [String]] = [:]
        let chunkSize = 900
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[chunkStart..<min(chunkStart + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT btl.book, t.name FROM books_tags_link btl
                JOIN tags t ON t.id = btl.tag
                WHERE btl.book IN (\(placeholders))
                ORDER BY btl.book, t.name
                """
            let args = chunk.map { $0 as Binding? }
            for row in try db.prepare(sql, args).map({ $0 }) {
                guard let cidBind = row[0] as? Int64,
                      let name   = row[1] as? String else { continue }
                let cid = Int(cidBind)
                result[cid, default: []].append(name)
            }
        }
        return result
    }

    internal func commentsInternal(for ids: [Int]) throws -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        let chunkSize = 900
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[chunkStart..<min(chunkStart + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT book, text FROM comments WHERE book IN (\(placeholders))"
            let args = chunk.map { $0 as Binding? }
            for row in try db.prepare(sql, args).map({ $0 }) {
                guard let cidBind = row[0] as? Int64,
                      let text   = row[1] as? String else { continue }
                result[Int(cidBind)] = text
            }
        }
        return result
    }

    // MARK: - Date parsing

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoWithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let ymdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    internal func parseDate(_ string: String) -> Date? {
        if let parsedDate = Self.isoWithFractional.date(from: string) { return parsedDate }
        if let parsedDate = Self.isoWithoutFractional.date(from: string) { return parsedDate }
        // Calibre SQLite timestamps often use a space separator ("YYYY-MM-DD HH:MM:SS[.ffffff]+00:00")
        let normalized = string.replacingOccurrences(of: " ", with: "T")
        if normalized != string {
            if let parsedDate = Self.isoWithFractional.date(from: normalized) { return parsedDate }
            if let parsedDate = Self.isoWithoutFractional.date(from: normalized) { return parsedDate }
        }
        return Self.ymdFormatter.date(from: string)
    }

    /// Fetches Calibre's `books.timestamp` (Date Added) for the given book IDs.
    func fetchDateAdded(for ids: [Int]) -> [Int: Date] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int: Date] = [:]
        for start in stride(from: 0, to: ids.count, by: 900) {
            let chunk = Array(ids[start..<min(start + 900, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT id, timestamp FROM books WHERE id IN (\(placeholders))"
            let bindings: [Binding?] = chunk.map { $0 as Binding? }
            guard let rows = try? db.prepare(sql, bindings) else { continue }
            for row in rows {
                guard let rawID = row[0] as? Int64,
                      let tsStr = row[1] as? String,
                      let date = parseDate(tsStr) else { continue }
                result[Int(rawID)] = date
            }
        }
        return result
    }

    /// Returns all Calibre book IDs that have an entry in `books_series_link`.
    func fetchCalibreSeriesBookIDs() -> Set<Int> {
        guard let rows = try? db.prepare("SELECT book FROM books_series_link", []) else { return [] }
        var result = Set<Int>()
        for row in rows {
            if let rawID = row[0] as? Int64 {
                result.insert(Int(rawID))
            }
        }
        return result
    }

    // MARK: - Custom column cache (lazy — must live in primary class declaration, not extension)

    private lazy var _customColumns: [CustomColumn] = {
        let sql = "SELECT id, label, datatype FROM custom_columns"
        guard let rows = try? db.prepare(sql, []).map({ $0 }) else { return [] }
        return rows.compactMap { row -> CustomColumn? in
            guard let id    = (row[0] as? Int64).map(Int.init),
                  let label = row[1] as? String,
                  let dtype = row[2] as? String else { return nil }
            return CustomColumn(id: id, label: label.lowercased(), dataType: dtype)
        }
    }()
}

// MARK: - EPUB path lookup

extension CalibreLibrary {
    /// Finds book IDs whose title (case-insensitive trimmed) and at least one author match.
    func findBookIDs(matchingNormalizedTitle title: String, authors: [String]) -> [Int] {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTitle.isEmpty else { return [] }
        let sql = "SELECT id FROM books WHERE LOWER(TRIM(title)) = ? LIMIT 25"
        guard let rows = try? db.prepare(sql, [normalizedTitle as Binding?]) else { return [] }
        let candidateIDs = rows.compactMap { row -> Int? in
            if let val = row[0] as? Int64 { return Int(val) }
            return row[0] as? Int
        }
        guard !candidateIDs.isEmpty else { return [] }
        let normalizedAuthors = Set(
            authors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !normalizedAuthors.isEmpty else { return candidateIDs }

        let books = booksForIDs(candidateIDs)
        return books.filter { book in
            let bookAuthors = Set(
                book.displayAuthors
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            )
            return !bookAuthors.isDisjoint(with: normalizedAuthors)
        }.map(\.id)
    }

    /// Returns the absolute URL of the EPUB file for the given Calibre book ID,
    /// or nil if the book is not found or has no .epub file.
    /// Handles both direct relative file paths and standard Calibre directories via data table / folder scans.
    func epubURL(calibreID: Int) -> URL? {
        let sql = """
            SELECT b.path, d.name, d.format
            FROM books b
            LEFT JOIN data d ON d.book = b.id AND d.format = 'EPUB'
            WHERE b.id = ?
            LIMIT 1
        """
        guard let rows = try? db.prepare(sql, [calibreID as Binding?]).map({ $0 }),
              let row = rows.first,
              let relativePath = row[0] as? String else { return nil }

        let itemURL = root.appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir) {
            if !isDir.boolValue && itemURL.pathExtension.lowercased() == "epub" {
                return itemURL
            }
        }

        if let name = row[1] as? String, let format = row[2] as? String {
            let candidate = itemURL.appendingPathComponent("\(name).\(format.lowercased())")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
                            at: itemURL, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension.lowercased() == "epub" }
    }
}

// MARK: - §6: Seeded RNG (Xorshift64)

/// A simple deterministic random number generator using the xorshift64 algorithm.
/// Not cryptographically secure — used only for reproducible random sort orders.
struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid zero state (xorshift64 returns 0 forever if seeded with 0)
        self.state = seed == 0 ? 6364136223846793005 : seed
    }

    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }
}

// MARK: - Fuzzy search helper

extension CalibreLibrary {
    /// Cap on trigram clauses generated per word. Each trigram adds one
    /// `LIKE` clause to the query; uncapped, a long word (e.g. a 20-character
    /// title fragment) generates 18 clauses on its own. 6 was chosen empirically
    /// against a real test library: it keeps the common typo/partial-title
    /// cases matching (which usually only need a handful of trigrams to
    /// disambiguate) while bounding worst-case clause count.
    private static let maxTrigramsPerWord = 6

    /// Above this word count, fuzzy per-word trigram matching is skipped in
    /// favor of plain multi-word AND-of-LIKE. A query with this many words is
    /// almost always a long title pasted in verbatim rather than a typo the
    /// trigram matching is meant to correct for, and the trigram cost scales
    /// with word count on top of the per-word cap above.
    private static let fuzzyWordCountLimit = 5

    static func fuzzyTitleCondition(for query: String) -> (String, [Binding?]) {
        let words = query
            .lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 2 }

        guard !words.isEmpty else { return ("1=1", []) }

        var clauses: [String] = []
        var args: [Binding?]  = []

        let useFuzzyMatching = words.count <= fuzzyWordCountLimit

        for word in words {
            if useFuzzyMatching && word.count >= 5 {
                let trigrams = Self.trigrams(for: word)
                let trigramClauses = trigrams.map { _ in "LOWER(b.title) LIKE ?" }
                    .joined(separator: " OR ")
                let exactClause = "LOWER(b.title) LIKE ?"
                clauses.append("(\(exactClause) OR \(trigramClauses))")
                args.append("%\(word)%" as Binding?)
                for trigram in trigrams { args.append("%\(trigram)%" as Binding?) }
            } else {
                clauses.append("LOWER(b.title) LIKE ?")
                args.append("%\(word)%" as Binding?)
            }
        }

        return (clauses.joined(separator: " AND "), args)
    }

    private static func trigrams(for word: String) -> [String] {
        let chars = Array(word)
        guard chars.count >= 3 else { return [word] }
        let allTrigrams = (0...(chars.count - 3)).map { String(chars[$0..<$0+3]) }
        guard allTrigrams.count > maxTrigramsPerWord else { return allTrigrams }
        // Evenly sample across the word rather than always taking the prefix,
        // so the cap doesn't silently ignore the back half of long words.
        let stride = Double(allTrigrams.count) / Double(maxTrigramsPerWord)
        var sampled: [String] = []
        var seenIndices = Set<Int>()
        for sampleIndex in 0..<maxTrigramsPerWord {
            let index = min(Int(Double(sampleIndex) * stride), allTrigrams.count - 1)
            if seenIndices.insert(index).inserted { sampled.append(allTrigrams[index]) }
        }
        return sampled
    }

    // MARK: - Custom column discovery

    struct CustomColumn {
        let id: Int
        let label: String
        let dataType: String
        var tableName: String { "custom_column_\(id)" }
    }

    /// Returns all custom columns defined in the library.
    func customColumns() -> [CustomColumn] { _customColumns }

    /// Returns the table name (e.g. "custom_column_3") for a given column label,
    /// case-insensitively. Returns nil if no matching column exists.
    func customColumnTableName(label: String) -> String? {
        customColumns().first {
            $0.label == label.lowercased()
        }?.tableName
    }

    /// §2a: Bulk-fetch integer custom column values for a set of book IDs.
    /// Uses WHERE book IN (...) — not per-book queries — to avoid N+1.
    /// (Moved here from FilterBuilder.swift — this is CalibreLibrary's data, not a filter concern.)
    func bulkCustomColumnInts(table: String, ids: [Int]) -> [Int: Int] {
        guard !ids.isEmpty else { return [:] }
        let sql = "SELECT book, value FROM \(table) WHERE \(SQLIDList.clause(column: "book"))"
        let args: [Binding?] = [SQLIDList.binding(ids)]
        guard let rows = try? db.prepare(sql, args).map({ $0 }) else { return [:] }
        var result: [Int: Int] = [:]
        for row in rows {
            if let idBind = row[0] as? Int64, let val = row[1] as? Int64 {
                result[Int(idBind)] = Int(val)
            }
        }
        return result
    }

    /// Count books within a given ID set (for the footer when a filter is active).
    func bookCount(ids: [Int]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let sql = "SELECT COUNT(*) FROM books WHERE \(SQLIDList.clause(column: "id"))"
        let args: [Binding?] = [SQLIDList.binding(ids)]
        return (try? db.scalar(sql, args) as? Int64).map(Int.init) ?? 0
    }
}

/// `(st_dev, st_ino)` of a file. Equal identities mean the same file, so a
/// changed identity means it was replaced rather than written in place.
struct CalibreFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    static func of(path: String) -> CalibreFileIdentity? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return CalibreFileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }
}
