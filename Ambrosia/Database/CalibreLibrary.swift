import SQLite
import Foundation

// MARK: - Sort field
//
// §6: Added .ao3Published, .ao3Updated (sort by ao3_metadata dates),
//     .random (seeded shuffle), and renamed nothing — existing cases unchanged.

enum SortField: String, CaseIterable, Identifiable {
    case title
    case author
    case wordCount
    case kudos
    case published      // Calibre pubdate column
    case series
    case ao3Published   // §6: ao3_metadata.published_date
    case ao3Updated     // §6: ao3_metadata.updated_date
    case random         // §6: seeded random order

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:        return "Title"
        case .author:       return "Author"
        case .wordCount:    return "Word Count"
        case .kudos:        return "Kudos"
        case .published:    return "Published (Calibre)"
        case .series:       return "Series"
        case .ao3Published: return "AO3 Published"
        case .ao3Updated:   return "AO3 Updated"
        case .random:       return "Random"
        }
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
    internal let db: Connection

    // MARK: - AO3 metadata caches
    //
    // `AmbrosiaMetaDB` is the sole owner of ambrosia_meta.db (Invariant 10).
    // CalibreLibrary used to open its own read-only `Connection` to that file,
    // which violated that ownership boundary. These three caches are bulk-
    // fetched by `AmbrosiaMetaDB` and pushed in by `LibrarySession` (on open
    // and after AO3 extraction completes) via `updateAO3MetaCaches`. The
    // methods below read from these caches instead of querying a database.
    private(set) var ao3WordCountCache: [Int: Int] = [:]
    private(set) var ao3DateCache: [Int: (published: String?, updated: String?)] = [:]
    private(set) var crossoverIDCache: Set<Int> = []

    /// §6: Seeded random sort seed. Stable within a session; refreshed on library open
    /// or when the user explicitly requests a new shuffle.
    private(set) var randomSeed: UInt64 = UInt64.random(in: 0 ... UInt64.max)

    init(root: URL) throws {
        self.root = root
        let dbPath = root.appendingPathComponent("metadata.db").path
        db = try Connection(dbPath, readonly: true)
        // Increase the page cache to 32 MB and keep temp tables in memory.
        // These are session-scoped PRAGMAs — safe on a read-only connection.
        try? db.execute("PRAGMA cache_size = -32768")   // negative = kibibytes
        try? db.execute("PRAGMA temp_store = MEMORY")
    }

    /// Called by `LibrarySession` whenever the AO3 metadata caches should be
    /// refreshed from `AmbrosiaMetaDB` (on library open and after extraction
    /// batches complete).
    func updateAO3MetaCaches(
        wordCounts: [Int: Int],
        dates: [Int: (published: String?, updated: String?)],
        crossoverIDs: Set<Int>
    ) {
        ao3WordCountCache = wordCounts
        ao3DateCache = dates
        crossoverIDCache = crossoverIDs
        // §Phase3: word-count-sorted pages and any page/count keyed on this
        // library's AO3 fields are now stale. Same actor reaching into its own
        // state, no version plumbing needed (see LRUCache note above pageCache).
        pageCache.removeAll()
        countCache.removeAll()
        groupAwareCountCache.removeAll()
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
    //    caller passes the current LibrarySession.membershipVersion into every
    //    cached method below as part of the key, so a stale entry simply never
    //    matches once the version has moved on.
    //  - AO3 extraction batch completes: updateAO3MetaCaches(...) clears both
    //    caches directly (same actor, no version plumbing needed).
    //  - Random reshuffle: covered by randomSeed being part of the key.
    var pageCache: LRUCache<PageCacheKey, (page: [CalibreBook], hasMore: Bool)> = LRUCache(limit: 48)
    var countCache: LRUCache<CountCacheKey, Int> = LRUCache(limit: 48)
    var groupAwareCountCache: LRUCache<GroupAwareCountCacheKey, Int> = LRUCache(limit: 48)

    // MARK: - Count

    /// Total books. Called once on open and refreshed after debounced search.
    func bookCount() -> Int {
        let rows = (try? db.prepare("SELECT COUNT(*) FROM books").map { $0 }) ?? []
        return (rows.first?.first as? Int64).map(Int.init) ?? 0
    }

    func allBookIDs() -> [Int] {
        let rows = (try? db.prepare("SELECT id FROM books ORDER BY id").map { $0 }) ?? []
        return rows.compactMap { row in
            if let value = row.first as? Int64 { return Int(value) }
            return row.first as? Int
        }
    }

    func allCalibreSeriesEntries() -> [SeriesCacheEntry] {
        let sql = """
        SELECT b.id, s.name, b.series_index
        FROM books b
        JOIN books_series_link bsl ON bsl.book = b.id
        JOIN series s ON s.id = bsl.series
        WHERE s.name IS NOT NULL AND TRIM(s.name) != ''
        ORDER BY s.name, b.series_index
        """
        let rows = (try? db.prepare(sql).map { $0 }) ?? []
        return rows.compactMap { row in
            guard let idBind = row[0] as? Int64,
                  let name = row[1] as? String else { return nil }
            let index: Int
            if let raw = row[2] as? Double {
                index = Int(raw.rounded())
            } else if let raw = row[2] as? Int64 {
                index = Int(raw)
            } else {
                index = 1
            }
            return SeriesCacheEntry(
                calibreID: Int(idBind),
                seriesName: name,
                seriesIndex: index,
                ao3SeriesID: nil,
                isAnthology: false
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
            if let value = row[0] as? Int64 { bookID = Int(value) }
            else { bookID = row[0] as? Int }
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
        for i in stride(from: arr.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            arr.swapAt(i, j)
        }
        return arr
    }

    // MARK: - §6: orderByClause — updated with new sort cases
    // ao3Published / ao3Updated: sort is resolved in-memory post-fetch via sortedByAO3Date.
    // SQL only needs a stable title-order baseline here; the cross-database JOIN that was
    // previously attempted here against ao3_metadata was always invalid (ao3_metadata lives
    // in ambrosia_meta.db, not metadata.db) and caused _fetchBooks to throw, returning [].
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
        case .published:
            return "b.pubdate \(direction), b.id ASC"
        case .series:
            return "s.name \(direction), b.series_index ASC, b.id ASC"
        case .ao3Published:
            // In-memory sort via sortedByAO3Date; SQL baseline only.
            return "b.title ASC, b.id ASC"
        case .ao3Updated:
            // In-memory sort via sortedByAO3Date; SQL baseline only.
            return "b.title ASC, b.id ASC"
        case .random:
            // Seeded random is handled post-fetch in the caller (sortedRandomly).
            return "b.title ASC, b.id ASC"
        }
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

    /// Bulk-fetch AO3 published/updated dates for a set of IDs from the
    /// cached `ao3DateCache` (see the AO3 metadata caches note above).
    /// Returns ISO-8601 date strings keyed by calibre ID. Missing entries = no AO3 metadata.
    func ao3Dates(ids: [Int]) -> [Int: (published: String?, updated: String?)] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        return ao3DateCache.filter { idSet.contains($0.key) }
    }

    /// Sort books by an AO3 date field (ISO-8601 string, lexicographic order).
    /// Books with no AO3 metadata sort last in both directions.
    func sortedByAO3Date(
        books: [CalibreBook],
        keyPath: KeyPath<(published: String?, updated: String?), String?>,
        ascending: Bool
    ) -> [CalibreBook] {
        let dates = ao3Dates(ids: books.map(\.id))
        return books.sorted { a, b in
            let av = dates[a.id].flatMap { $0[keyPath: keyPath] }
            let bv = dates[b.id].flatMap { $0[keyPath: keyPath] }
            switch (av, bv) {
            case (nil, nil): return a.title < b.title
            case (nil, _):   return false
            case (_, nil):   return true
            case let (x?, y?): return ascending ? x < y : x > y
            }
        }
    }

    /// Nil-safe comparator shared by every in-memory sort that may have missing
    /// values for some books (word count, kudos, etc). Books with no value always
    /// sort last, regardless of ascending/descending — there is no natural "low" or
    /// "high" placement for "we don't know".
    func compareNilsLast(_ x: Int?, _ y: Int?, ascending: Bool) -> Bool {
        switch (x, y) {
        case (nil, nil): return false
        case (nil, _):    return false
        case (_, nil):    return true
        case let (xv?, yv?): return ascending ? xv < yv : xv > yv
        }
    }

    /// §2a fix (2): word-count sort, resolved entirely in Swift.
    ///
    /// Primary source: a configured Calibre custom column (bulk-fetched, not
    /// per-book). Fallback: ao3_metadata.word_count, supplied by the caller via
    /// `ao3WordCounts` (already bulk-fetched from ambrosia_meta.db — a separate
    /// database file, so it can't be expressed as a SQL JOIN against books.db).
    ///
    /// Sorting requires the *entire* matching set, not just one page — a per-page
    /// sort would be locally correct but globally meaningless across page
    /// boundaries. The SQL layer therefore only fetches a stable title-ordered
    /// baseline (see orderByClause(.wordCount)); this function re-sorts that full
    /// set in memory and the caller slices out the requested page.
    func sortedByWordCount(books: [CalibreBook], ascending: Bool,
                            ao3WordCounts: [Int: Int]) -> [CalibreBook] {
        let valuesByID: [Int: Int]
        if let label = CustomColumnConfig.shared.wordCountLabel,
           let tbl = customColumnTableName(label: label) {
            valuesByID = bulkCustomColumnInts(table: tbl, ids: books.map(\.id))
        } else {
            valuesByID = ao3WordCounts
        }
        return books.sorted { a, b in
            compareNilsLast(valuesByID[a.id], valuesByID[b.id], ascending: ascending)
        }
    }

    /// Fetches the full matching set (capped at exportCap, same cap as export),
    /// sorts it by word count in memory, and returns just the requested page plus
    /// whether more pages remain. Used in place of the normal offset/limit SQL
    /// path whenever sort == .wordCount.
    func wordCountSortedPage(offset: Int, limit: Int, ascending: Bool,
                              query: SearchQuery, filter: FilterExpression?,
                              restrictIDs: [Int]?,
                              visibility: LibraryVisibilityPolicy = .allowAll,
                              filterTagExpansions: [String: [String]] = [:],
                              visibilityVersion: Int = 0) -> (page: [CalibreBook], hasMore: Bool) {
        let cacheKey = PageCacheKey(
            querySignature: LibraryFilterDebug.summary(query: query),
            filterSignature: filter.map { LibraryFilterDebug.summary(expression: $0) } ?? "",
            tagExpansionsDigest: tagExpansionsDigest(filterTagExpansions),
            visibilityVersion: visibilityVersion,
            sortField: .wordCount,
            ascending: ascending,
            randomSeed: randomSeed,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] { return cached }
        // 1. Fetch all matching IDs (no author/tag/comment hydration), then
        // apply the visibility policy (skip/series-grouping/AO3-publisher-only/
        // anthology) once, here, instead of callers pre-intersecting restrictIDs
        // with individual ID sets at each call site.
        let matchedIDs = fetchAllMatchingIDs(query: query, filter: filter, restrictIDs: restrictIDs,
                                         filterTagExpansions: filterTagExpansions)
        let allIDs = visibility.filter(matchedIDs)

        // 2. Bulk-fetch word counts for this ID set only.
        let wordCounts: [Int: Int]
        if let label = CustomColumnConfig.shared.wordCountLabel,
           let tbl = customColumnTableName(label: label) {
            wordCounts = bulkCustomColumnInts(table: tbl, ids: allIDs)
        } else {
            wordCounts = ao3WordCounts(ids: allIDs)
        }

        // 3. Sort IDs by word count in Swift. Unknown word count sorts last.
        let sortedIDs = allIDs.sorted { a, b in
            compareNilsLast(wordCounts[a], wordCounts[b], ascending: ascending)
        }

        // 4. Slice the requested page.
        let start = min(offset, sortedIDs.count)
        let end   = min(offset + limit, sortedIDs.count)
        guard start < end else {
            pageCache.set(([], false), for: cacheKey)
            return ([], false)
        }
        let pageIDs = Array(sortedIDs[start..<end])

        // 5. Hydrate only the page (authors, tags, comments).
        let page = booksForIDs(pageIDs)
        let result = (page, end < sortedIDs.count)
        pageCache.set(result, for: cacheKey)
        return result
    }

    /// Group-aware total: the count of matching books that would actually be
    /// shown once skip/series-grouping/AO3-publisher/anthology visibility is
    /// applied — not the raw SQL row count `fetchAllMatchingIDs` alone would
    /// give (which double-counts collapsed series members and ignores the
    /// publisher/anthology toggles). Used for "Page X of Y" in grouped mode.
    ///
    /// This is pure ID-set arithmetic, not a hydration cost: `visibility`'s
    /// `isVisible(_ id: Int)` form already resolves `hideNonAO3PublisherBooks`/
    /// `hideAnthologyBooks` against the pre-computed `ao3PublisherIDs`/
    /// `anthologyIDs` sets the caller passes in (see LibraryVisibilityPolicy),
    /// so no `CalibreBook` hydration is required — matching IDs in, visible
    /// IDs out.
    func visibleBookCount(
        query: SearchQuery,
        filter: FilterExpression?,
        restrictIDs: [Int]?,
        visibility: LibraryVisibilityPolicy,
        filterTagExpansions: [String: [String]] = [:],
        visibilityVersion: Int = 0
    ) -> Int {
        let cacheKey = GroupAwareCountCacheKey(
            querySignature: LibraryFilterDebug.summary(query: query),
            filterSignature: filter.map { LibraryFilterDebug.summary(expression: $0) } ?? "",
            tagExpansionsDigest: tagExpansionsDigest(filterTagExpansions),
            visibilityVersion: visibilityVersion,
            showSkippedCollection: visibility.showSkippedCollection,
            hideNonAO3PublisherBooks: visibility.hideNonAO3PublisherBooks,
            hideAnthologyBooks: visibility.hideAnthologyBooks
        )
        if let cached = groupAwareCountCache[cacheKey] { return cached }
        let matchedIDs = fetchAllMatchingIDs(query: query, filter: filter, restrictIDs: restrictIDs,
                                              filterTagExpansions: filterTagExpansions)
        let count = visibility.filter(matchedIDs).count
        groupAwareCountCache.set(count, for: cacheKey)
        return count
    }

    /// Random-sorted page, analogous to wordCountSortedPage.
    /// Fetches all matching IDs, shuffles with the current seed, slices the page.
    func randomSortedPage(offset: Int, limit: Int,
                           query: SearchQuery, filter: FilterExpression?,
                           restrictIDs: [Int]?,
                           visibility: LibraryVisibilityPolicy = .allowAll,
                           filterTagExpansions: [String: [String]] = [:],
                           visibilityVersion: Int = 0) -> (page: [CalibreBook], hasMore: Bool) {
        let cacheKey = PageCacheKey(
            querySignature: LibraryFilterDebug.summary(query: query),
            filterSignature: filter.map { LibraryFilterDebug.summary(expression: $0) } ?? "",
            tagExpansionsDigest: tagExpansionsDigest(filterTagExpansions),
            visibilityVersion: visibilityVersion,
            sortField: .random,
            ascending: true,
            randomSeed: randomSeed,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] { return cached }
        let matchedIDs = fetchAllMatchingIDs(query: query, filter: filter, restrictIDs: restrictIDs,
                                         filterTagExpansions: filterTagExpansions)
        let allIDs = visibility.filter(matchedIDs)
        let sortedIDs = sortedRandomly(allIDs)
        let start = min(offset, sortedIDs.count)
        let end   = min(offset + limit, sortedIDs.count)
        guard start < end else {
            pageCache.set(([], false), for: cacheKey)
            return ([], false)
        }
        let pageIDs = Array(sortedIDs[start..<end])
        let page = booksForIDs(pageIDs)
        let result = (page, end < sortedIDs.count)
        pageCache.set(result, for: cacheKey)
        return result
    }

    // MARK: - §1: fetchAllMatchingIDs (lightweight — IDs only, no hydration)
    //
    // Used by wordCountSortedPage to get the full matching set without the cost of
    // hydrating authors, tags, and comments for every book. The authors LEFT JOIN is
    // kept because whereClause may emit author conditions; tags and comments joins
    // are omitted (never referenced in WHERE by _fetchBooks).

    func fetchAllMatchingIDs(
        query: SearchQuery,
        filter: FilterExpression?,
        restrictIDs: [Int]?,
        filterTagExpansions: [String: [String]] = [:]
    ) -> [Int] {
        var conditions: [String] = []
        var args: [Binding?] = []

        if let ids = restrictIDs, !ids.isEmpty {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            conditions.append("b.id IN (\(ph))")
            args.append(contentsOf: ids.map { $0 as Binding? })
        }
        let (qClause, qArgs) = whereClause(for: query)
        if !qClause.isEmpty {
            conditions.append(qClause)
            args.append(contentsOf: qArgs)
        }
        if let filter, let (fClause, fArgs) = sqlFilterClause(for: filter, tagExpansions: filterTagExpansions) {
            conditions.append(fClause)
            args.append(contentsOf: fArgs)
        }
        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        // §perf: Only join `comments` when a filter rule references the comment field.
        let needsCommentJoin = filter?.groups.flatMap(\.completeRules)
            .contains { $0.field == .comment } == true
        let commentJoin = needsCommentJoin ? "LEFT JOIN comments c ON c.book = b.id" : ""
        let sql = """
            SELECT b.id FROM books b
            LEFT JOIN books_authors_link bal ON bal.book = b.id
            LEFT JOIN authors a ON a.id = bal.author
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            \(commentJoin)
            \(where_)
            GROUP BY b.id
            ORDER BY b.title ASC
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
            let rows = try _fetchBooks(
                offset: 0, limit: cap + 1,
                sort: sort, ascending: ascending,
                query: query, filter: filter,
                restrictIDs: ids
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try _authors(for: fetchedIDs)
            let tagsMap     = try _tags(for: fetchedIDs)
            let commentsMap = try _comments(for: fetchedIDs)
            return rows.prefix(cap).map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags    = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
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
        visibilityVersion: Int = 0
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
            sortField: sort,
            ascending: ascending,
            randomSeed: randomSeed,
            offset: offset,
            limit: limit
        )
        if let cached = pageCache[cacheKey] {
            LibraryFilterDebug.log("books.cacheHit", ["rows": cached.page.count])
            return cached.page
        }
        let start = LibraryFilterDebug.now()
        do {
            let rows = try _fetchBooks(
                offset: offset, limit: limit,
                sort: sort, ascending: ascending,
                query: query, filter: filter,
                restrictIDs: nil,
                filterTagExpansions: filterTagExpansions
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try _authors(for: fetchedIDs)
            let tagsMap     = try _tags(for: fetchedIDs)
            let commentsMap = try _comments(for: fetchedIDs)
            LibraryFilterDebug.log("books.end", [
                "rows": rows.count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: start)
            ])
            var result = rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags    = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
            switch sort {
            case .ao3Published:
                result = sortedByAO3Date(books: result, keyPath: \.published, ascending: ascending)
            case .ao3Updated:
                result = sortedByAO3Date(books: result, keyPath: \.updated, ascending: ascending)
            default:
                break
            }
            // hasMore is not knowable from this overload alone (callers infer it
            // from rows.count vs the limit they passed); store false as a filler,
            // it is never read back — only `.page` is used by this overload's callers.
            pageCache.set((result, false), for: cacheKey)
            return result
        } catch {
            #if DEBUG
            print("[CalibreLibrary] books error: \(error)")
            #endif
            return []
        }
    }

    // MARK: - Internal fetch implementation

    func _fetchBooks(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery,
        filter: FilterExpression?,
        restrictIDs: [Int]? = nil,
        filterTagExpansions: [String: [String]] = [:]
    ) throws -> [CalibreBook] {
        let direction = ascending ? "ASC" : "DESC"
        // §6 fix: random sort falls back to title in SQL; caller reshuffles post-fetch.
        let orderBy = orderByClause(sort: sort, direction: direction)

        // §6 + §2a: Add kudos LEFT JOIN only when sorting by kudos. (Word-count's
        // wcJoin was removed — word-count sort is now resolved in Swift; see
        // wordCountSortedPage(...) / orderByClause(.wordCount) above.)
        let kJoin: String = {
            guard sort == .kudos, let tbl = kudosCustomColumnTable() else { return "" }
            return "LEFT JOIN \(tbl) k ON k.book = b.id"
        }()

        // §perf: Only join `comments` when a filter rule references the comment field.
        // `comments` stores large HTML blobs; joining it unconditionally forces SQLite to
        // walk the table for every query even though the comment text is never read from
        // the main row (it is bulk-fetched separately by _comments(for:)).
        let needsCommentJoin = filter?.groups.flatMap(\.completeRules)
            .contains { $0.field == .comment } == true
        let commentJoin = needsCommentJoin ? "LEFT JOIN comments c ON c.book = b.id" : ""

        var conditions: [String] = []
        var args: [Binding?] = []

        // Restrict to explicit ID set (FilterResult path)
        if let ids = restrictIDs, !ids.isEmpty {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            conditions.append("b.id IN (\(ph))")
            args.append(contentsOf: ids.map { $0 as Binding? })
        }

        let (qClause, qArgs) = whereClause(for: query)
        if !qClause.isEmpty {
            conditions.append(qClause)
            args.append(contentsOf: qArgs)
        }
        if let filter, let (fClause, fArgs) = sqlFilterClause(for: filter, tagExpansions: filterTagExpansions) {
            conditions.append(fClause)
            args.append(contentsOf: fArgs)
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        // §perf: DROP `SELECT DISTINCT` — `GROUP BY b.id` already deduplicates. DISTINCT
        // on top of GROUP BY adds a redundant sort+hash step that costs ~30 % of query time
        // on large libraries with multi-author or multi-series books.
        let sql = """
            SELECT b.id, b.title, b.path, b.pubdate, s.name, b.series_index, p.name
            FROM books b
            LEFT JOIN books_authors_link bal ON bal.book = b.id
            LEFT JOIN authors a ON a.id = bal.author
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            LEFT JOIN books_publishers_link bpl ON bpl.book = b.id
            LEFT JOIN publishers p ON p.id = bpl.publisher
            \(commentJoin)
            \(kJoin)
            \(where_)
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
                id:            Int(idBind),
                title:         title,
                series:        row[4] as? String,
                seriesIndex:   row[5] as? Double,
                wordCount:     nil,  // populated by bulk custom-column fetch in caller
                kudos:         nil,
                publishedDate: (row[3] as? String).flatMap(parseDate),
                publisher:     row[6] as? String,
                relativePath:  path
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
            let rows = try _fetchBooksQueryIDs(
                ids: ids, offset: offset, limit: limit,
                sort: sort, ascending: ascending, query: query)
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try _authors(for: fetchedIDs)
            let tagsMap     = try _tags(for: fetchedIDs)
            let commentsMap = try _comments(for: fetchedIDs)
            var books = rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags    = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
            switch sort {
            case .ao3Published:
                books = sortedByAO3Date(books: books, keyPath: \.published, ascending: ascending)
            case .ao3Updated:
                books = sortedByAO3Date(books: books, keyPath: \.updated, ascending: ascending)
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

    func booksForIDs(_ ids: [Int]) -> [CalibreBook] {
        guard !ids.isEmpty else { return [] }
        do {
            let rows = try _fetchBooksQueryIDs(
                ids: ids,
                offset: 0,
                limit: max(ids.count, 1),
                sort: .title,
                ascending: true,
                query: SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap = try _authors(for: fetchedIDs)
            let tagsMap = try _tags(for: fetchedIDs)
            let commentsMap = try _comments(for: fetchedIDs)
            return rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
        } catch {
            #if DEBUG
            print("[CalibreLibrary] booksForIDs error: \(error)")
            #endif
            return []
        }
    }

    private func _fetchBooksQueryIDs(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery
    ) throws -> [CalibreBook] {
        try _fetchBooks(
            offset: offset, limit: limit,
            sort: sort, ascending: ascending,
            query: query, filter: nil,
            restrictIDs: ids
        )
    }

    // MARK: - Bulk metadata helpers

    internal func _authors(for ids: [Int]) throws -> [Int: [String]] {
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

    internal func _tags(for ids: [Int]) throws -> [Int: [String]] {
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

    internal func _comments(for ids: [Int]) throws -> [Int: String] {
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoWithoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    internal func parseDate(_ string: String) -> Date? {
        if let d = Self.isoWithFractional.date(from: string) { return d }
        if let d = Self.isoWithoutFractional.date(from: string) { return d }
        return Self.ymdFormatter.date(from: string)
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
    /// Returns the absolute URL of the EPUB file for the given Calibre book ID,
    /// or nil if the book is not found or has no .epub file in its folder.
    /// Uses a lightweight single-column query — does not fetch authors/tags/comments.
    /// Mirrors the FileManager scan in CalibreBook.epubURL(libraryRoot:).
    func epubURL(calibreID: Int) -> URL? {
        let sql = "SELECT path FROM books WHERE id = ? LIMIT 1"
        guard let rows = try? db.prepare(sql, [calibreID as Binding?]).map({ $0 }),
              let row = rows.first,
              let relativePath = row[0] as? String else { return nil }
        let folder = root.appendingPathComponent(relativePath)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
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
                for t in trigrams { args.append("%\(t)%" as Binding?) }
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
        for i in 0..<maxTrigramsPerWord {
            let index = min(Int(Double(i) * stride), allTrigrams.count - 1)
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

    /// Reads the integer value for a custom column for a single book.
    func customColumnInt(calibreID: Int, columnLabel: String) -> Int? {
        guard let tbl = customColumnTableName(label: columnLabel) else { return nil }
        let sql = "SELECT value FROM \(tbl) WHERE book = ?"
        guard let rows = try? db.prepare(sql, [calibreID as Binding?]).map({ $0 }),
              let first = rows.first,
              let v = first[0] as? Int64 else { return nil }
        return Int(v)
    }

    /// §2a: Bulk-fetch integer custom column values for a set of book IDs.
    /// Uses WHERE book IN (...) — not per-book queries — to avoid N+1.
    /// (Moved here from FilterBuilder.swift — this is CalibreLibrary's data, not a filter concern.)
    func bulkCustomColumnInts(table: String, ids: [Int]) -> [Int: Int] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT book, value FROM \(table) WHERE book IN (\(placeholders))"
        let args = ids.map { $0 as Binding? }
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
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT COUNT(*) FROM books WHERE id IN (\(placeholders))"
        let args = ids.map { $0 as Binding? }
        return (try? db.scalar(sql, args) as? Int64).map(Int.init) ?? 0
    }
}
