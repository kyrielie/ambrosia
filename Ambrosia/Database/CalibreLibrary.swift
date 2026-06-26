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
    case lastOpened
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
        case .lastOpened:   return "Last Opened"
        case .series:       return "Series"
        case .ao3Published: return "AO3 Published"
        case .ao3Updated:   return "AO3 Updated"
        case .random:       return "Random"
        }
    }

    /// Whether this sort field requires a JOIN against ao3_metadata.
    /// Used by _fetchBooks to decide whether to add the optional JOIN.
    var requiresAO3MetadataJoin: Bool {
        self == .ao3Published || self == .ao3Updated
    }
}

// MARK: - CalibreLibrary

/// Read-only query layer over Calibre's metadata.db.
/// All queries are synchronous — SQLite on a local file returns in <1ms.
/// One instance per open library; replaced wholesale when the user switches libraries.
final class CalibreLibrary {

    let root: URL                   // absolute path to the Calibre library folder
    internal let db: Connection

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
        let rows = (try? db.prepare(
            """
            SELECT book
            FROM comments
            WHERE LOWER(LTRIM(text)) LIKE 'anthology%'
            """
        ).map { $0 }) ?? []
        return Set(rows.compactMap { row in
            if let value = row[0] as? Int64 { return Int(value) }
            return row[0] as? Int
        })
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
    func crossoverBookIDs(metaDBPath: String) -> Set<Int> {
        guard let metaDB = try? Connection(metaDBPath, readonly: true) else { return [] }
        let sql = """
        SELECT calibre_id
        FROM ao3_metadata
        WHERE json_array_length(fandoms_json) > 1
        """
        let rows = (try? metaDB.prepare(sql).map { $0 }) ?? []
        return Set(rows.compactMap { row in
            if let v = row[0] as? Int64 { return Int(v) }
            return row[0] as? Int
        })
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
    //
    // ao3Published / ao3Updated require a LEFT JOIN against ao3_metadata.
    // The join is added by _fetchBooks when sort.requiresAO3MetadataJoin == true.
    // NULLs sort last in both directions: NULLS LAST is explicit for clarity.
    // SQLite does not support NULLS LAST natively but we achieve it by coalescing
    // to a sentinel:
    //   - ascending:  COALESCE(date, '0000') — blank dates sort before real ones → last when ASC
    //   We use '' which sorts before any real ISO date in ASCII order.
    //   - descending: COALESCE(date, '9999-99-99') — sorts after any real date → last when DESC
    //
    // wordCount: §2a fix — the old expression referenced a non-existent
    // custom_column_wordcount column directly on `books`. Fixed to use the
    // wcJoin LEFT JOIN alias `wc`.
    func orderByClause(sort: SortField, direction: String) -> String {
        switch sort {
        case .title:
            return "b.title \(direction)"
        case .author:
            return "MIN(a.sort) \(direction), b.title ASC"
        case .wordCount:
            // §2a fix (2): the wc.value JOIN approach is broken whenever no Calibre
            // custom column is configured (wcJoin is empty in that case, so wc.value
            // doesn't exist -> SQL error -> _fetchBooks throws -> books() catches it
            // and returns [], i.e. word-count sort silently shows an empty library).
            // ao3_metadata.word_count also can't be reached from this query at all --
            // it lives in a separate database file (ambrosia_meta.db), and cross-database
            // JOINs are not used anywhere in this codebase (see §6/§2a notes elsewhere).
            // Word-count sort is therefore resolved entirely in Swift, in the caller,
            // via wordCountSortedPage(...) / sortedByWordCount(...) below. SQL only
            // needs a stable baseline order here, exactly like .random.
            return "b.title \(direction)"
        case .kudos:
            return "COALESCE(k.value, 0) \(direction)"
        case .published:
            return "b.pubdate \(direction)"
        case .lastOpened:
            return "b.title \(direction)"
        case .series:
            return "s.name \(direction), b.series_index ASC"
        case .ao3Published:
            // §6: Sort by ao3_metadata.published_date (ISO text, lexicographic == chronological).
            // NULLs last in both directions.
            let sentinel = direction == "ASC" ? "''" : "'9999-99-99'"
            return "COALESCE(ao3m.published_date, \(sentinel)) \(direction), b.title ASC"
        case .ao3Updated:
            // §6: Sort by ao3_metadata.updated_date.
            let sentinel = direction == "ASC" ? "''" : "'9999-99-99'"
            return "COALESCE(ao3m.updated_date, \(sentinel)) \(direction), b.title ASC"
        case .random:
            // §6: Seeded random is handled post-fetch in the caller (sortedRandomly).
            // Fall back to title so the SQL ORDER BY is stable — post-sort will reshuffle.
            return "b.title ASC"
        }
    }

    // MARK: - §6: Shared AO3 metadata sort helper
    //
    // Called by both _fetchBooks (search/filter path) and books(ids:…) (explicit-IDs path)
    // to add the ao3_metadata JOIN when the sort field requires it and to compute the
    // word-count custom column JOIN alias name when sorting by word count.

    /// Returns the table name for the kudos custom column.
    func kudosCustomColumnTable() -> String? {
        let label = CustomColumnConfig.shared.kudosLabel ?? "kudos"
        return customColumnTableName(label: label)
    }

    // MARK: - §6: Bulk AO3 word-count fallback
    //
    // When no Calibre custom column for word count is configured, the caller can pass
    // a wordCountFallbackMap built from ao3_metadata.word_count. This function
    // bulk-fetches those values from the AmbrosiaMetaDB so the call site does not
    // need to reach into the AmbrosiaMetaDB actor directly at query time.
    //
    // The metaDBPath is passed in because CalibreLibrary does not hold a reference
    // to AmbrosiaMetaDB (they are different SQLite files, opened independently).
    func ao3WordCounts(metaDBPath: String, ids: [Int]) -> [Int: Int] {
        guard !ids.isEmpty, let metaDB = try? Connection(metaDBPath, readonly: true) else { return [:] }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT calibre_id, word_count FROM ao3_metadata WHERE calibre_id IN (\(ph)) AND word_count IS NOT NULL"
        let args = ids.map { $0 as Binding? }
        guard let rows = try? metaDB.prepare(sql, args).map({ $0 }) else { return [:] }
        var result: [Int: Int] = [:]
        for row in rows {
            if let idBind = row[0] as? Int64, let wc = row[1] as? Int64 {
                result[Int(idBind)] = Int(wc)
            }
        }
        return result
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
                              restrictIDs: [Int]?, metaDBPath: String?) -> (page: [CalibreBook], hasMore: Bool) {
        let all = fetchAllMatchingBooks(ids: restrictIDs, query: query, filter: filter,
                                        sort: .title, ascending: true)
        let ao3Counts = metaDBPath.map { ao3WordCounts(metaDBPath: $0, ids: all.map(\.id)) } ?? [:]
        let usingCustomColumn = CustomColumnConfig.shared.wordCountLabel != nil
        print("[WordCountSort] totalBooks=\(all.count) ao3CountsFound=\(ao3Counts.count) usingCustomColumn=\(usingCustomColumn) label=\(CustomColumnConfig.shared.wordCountLabel ?? "nil") offset=\(offset) limit=\(limit) ascending=\(ascending)")
        let sorted = sortedByWordCount(books: all, ascending: ascending, ao3WordCounts: ao3Counts)
        let start = min(offset, sorted.count)
        let end = min(offset + limit, sorted.count)
        let page = start < end ? Array(sorted[start..<end]) : []
        let sampleDesc = page.prefix(5).map { book in
            let wc = ao3Counts[book.id].map(String.init) ?? "nil"
            return "\(book.id):\(wc)"
        }.joined(separator: ", ")
        print("[WordCountSort] page=[\(sampleDesc)] hasMore=\(end < sorted.count)")
        return (page, end < sorted.count)
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
            print("[CalibreLibrary] fetchAllMatchingBooks error: \(error)")
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
        filter: FilterExpression? = nil
    ) -> [CalibreBook] {
        let start = LibraryFilterDebug.now()
        do {
            let rows = try _fetchBooks(
                offset: offset, limit: limit,
                sort: sort, ascending: ascending,
                query: query, filter: filter,
                restrictIDs: nil
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try _authors(for: fetchedIDs)
            let tagsMap     = try _tags(for: fetchedIDs)
            let commentsMap = try _comments(for: fetchedIDs)
            LibraryFilterDebug.log("books.end", [
                "rows": rows.count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: start)
            ])
            return rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags    = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
        } catch {
            print("[CalibreLibrary] books error: \(error)")
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
        restrictIDs: [Int]? = nil
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
        // §6: ao3_metadata JOIN for date-based sorts.
        let ao3Join: String = sort.requiresAO3MetadataJoin
            ? "LEFT JOIN ao3_metadata ao3m ON ao3m.calibre_id = b.id"
            : ""

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
        if let filter, let (fClause, fArgs) = sqlFilterClause(for: filter) {
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
            \(ao3Join)
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
    func books(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
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
            let books = rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags    = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
            LibraryFilterDebug.log("books.page.end", [
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
            print("[CalibreLibrary] books(ids:query:) error: \(error)")
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
            print("[CalibreLibrary] booksForIDs error: \(error)")
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
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT bal.book, a.name FROM books_authors_link bal
            JOIN authors a ON a.id = bal.author
            WHERE bal.book IN (\(placeholders))
            ORDER BY bal.book, a.id
            """
        let args = ids.map { $0 as Binding? }
        var result: [Int: [String]] = [:]
        for row in try db.prepare(sql, args).map({ $0 }) {
            guard let cidBind = row[0] as? Int64,
                  let name   = row[1] as? String else { continue }
            let cid = Int(cidBind)
            result[cid, default: []].append(name)
        }
        return result
    }

    internal func _tags(for ids: [Int]) throws -> [Int: [String]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT btl.book, t.name FROM books_tags_link btl
            JOIN tags t ON t.id = btl.tag
            WHERE btl.book IN (\(placeholders))
            ORDER BY btl.book, t.name
            """
        let args = ids.map { $0 as Binding? }
        var result: [Int: [String]] = [:]
        for row in try db.prepare(sql, args).map({ $0 }) {
            guard let cidBind = row[0] as? Int64,
                  let name   = row[1] as? String else { continue }
            let cid = Int(cidBind)
            result[cid, default: []].append(name)
        }
        return result
    }

    internal func _comments(for ids: [Int]) throws -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT book, text FROM comments WHERE book IN (\(placeholders))"
        let args = ids.map { $0 as Binding? }
        var result: [Int: String] = [:]
        for row in try db.prepare(sql, args).map({ $0 }) {
            guard let cidBind = row[0] as? Int64,
                  let text   = row[1] as? String else { continue }
            result[Int(cidBind)] = text
        }
        return result
    }

    // MARK: - Date parsing

    internal func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
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
    static func fuzzyTitleCondition(for query: String) -> (String, [Binding?]) {
        let words = query
            .lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 2 }

        guard !words.isEmpty else { return ("1=1", []) }

        var clauses: [String] = []
        var args: [Binding?]  = []

        for word in words {
            if word.count >= 5 {
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
        return (0...(chars.count - 3)).map { String(chars[$0..<$0+3]) }
    }

    // MARK: - Custom column discovery

    struct CustomColumn {
        let id: Int
        let label: String
        let dataType: String
        var tableName: String { "custom_column_\(id)" }
    }

    /// Returns all custom columns defined in the library.
    func customColumns() -> [CustomColumn] {
        let sql = "SELECT id, label, datatype FROM custom_columns"
        guard let rows = try? db.prepare(sql, []).map({ $0 }) else { return [] }
        return rows.compactMap { row -> CustomColumn? in
            guard let id    = (row[0] as? Int64).map(Int.init),
                  let label = row[1] as? String,
                  let dtype = row[2] as? String else { return nil }
            return CustomColumn(id: id, label: label.lowercased(), dataType: dtype)
        }
    }

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
