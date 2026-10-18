// SPDX-License-Identifier: GPL-3.0-only
import SQLite
import SQLite3
import Foundation

// MARK: - CalibreFTSLibrary (Section I3)

/// Optional read-only connection to Calibre's `full-text-search.db`.
///
/// Two modes (D7):
///   - `native`: runs a real FTS5 `MATCH` against `books_fts`, with the Calibre-compatible
///     `calibre` tokenizer registered on this connection (see `docs/calibre-fts.md`).
///   - `likeFallback`: `LIKE` scan over `books_text.searchable_text`, used only when
///     native mode could not be established (tokenizer registration failed, or the file's
///     `user_version` is not the one this code was written against).
///
/// Invariants:
///   - Opened `readonly: true`. Never written to, no write PRAGMAs, no hot-journal
///     recovery (D21). A read-only failure surfaces as `FTSSearchError.sqlite`.
///   - No `LIMIT` anywhere (D8). Ids only, unranked, `DISTINCT book` (D11).
///   - Lock discipline (D20): every statement is drained into memory and reset with no
///     suspension point in between; `BEGIN` is never issued.
///   - The only off-actor touch of the `sqlite3 *` is `SearchControl` calling
///     `sqlite3_interrupt` (Invariant 24).
///   - Every call checks the file identity first (D19): if Calibre deleted and recreated
///     the file, the connection is reopened instead of serving the unlinked old file.
actor CalibreFTSLibrary {

    enum Mode: Sendable, Equatable { case native, likeFallback }

    /// `(st_dev, st_ino)` of the FTS file.
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Opened {
        let conn: Connection
        let mode: Mode
        let identity: FileIdentity
        let reason: String
    }

    nonisolated let control: SearchControl
    private let ftsURL: URL
    private var db: Connection
    private var identity: FileIdentity
    private(set) var mode: Mode

    // MARK: - Init

    init?(libraryURL: URL) {
        let url = libraryURL.appendingPathComponent("full-text-search.db")
        guard let opened = Self.openConnection(ftsURL: url) else { return nil }
        Self.log("open mode=\(opened.mode == .native ? "native" : "likeFallback") reason=\(opened.reason)")
        self.ftsURL = url
        self.db = opened.conn
        self.identity = opened.identity
        self.mode = opened.mode
        self.control = SearchControl(handle: opened.conn.handle)
    }

    /// Steps 1 to 6 of the open sequence. Returns nil when the file is missing, cannot be
    /// opened, or does not have the `books_text` table this code needs.
    private static func openConnection(ftsURL: URL) -> Opened? {
        guard FileManager.default.fileExists(atPath: ftsURL.path) else {
            log("missing full-text-search.db at \(ftsURL.path)")
            return nil
        }
        // Identity is read BEFORE opening: if the file is replaced in between, the stored
        // identity is the old one, the next call sees a mismatch and reopens. Reading it
        // after opening could pair the new identity with the old file.
        guard let identity = fileIdentity(at: ftsURL) else {
            log("could not stat \(ftsURL.path)")
            return nil
        }
        let conn: Connection
        do {
            conn = try Connection(ftsURL.path, readonly: true)
        } catch {
            log("could not open full-text-search.db read-only: \(error)")
            return nil
        }
        conn.busyTimeout = 10   // D14: matches Calibre's own 10 s busy timeout

        var registered = false
        do {
            try CalibreTokenizerRegistration.register(on: conn)
            registered = true
        } catch {
            log("tokenizer registration failed: \(error)")
        }

        guard hasRequiredTextColumns(conn) else {
            log("unsupported FTS schema in \(ftsURL.path)")
            return nil
        }
        guard registered else {
            return Opened(conn: conn, mode: .likeFallback, identity: identity, reason: "tokenizer registration failed")
        }
        let userVersion: Int64? = (try? conn.scalar("PRAGMA user_version")).flatMap { $0 as? Int64 }
        guard userVersion == 1 else {
            return Opened(conn: conn, mode: .likeFallback, identity: identity,
                          reason: "user_version=\(userVersion.map(String.init) ?? "unreadable"), expected 1")
        }
        do {
            // Stepping the statement proves the tokenizer resolves for books_fts.
            let probe = try conn.prepare("SELECT 1 FROM books_fts WHERE books_fts MATCH 'a' LIMIT 1")
            defer { probe.reset() }
            _ = try probe.step()
        } catch {
            return Opened(conn: conn, mode: .likeFallback, identity: identity, reason: "books_fts probe failed: \(error)")
        }
        return Opened(conn: conn, mode: .native, identity: identity, reason: "ok")
    }

    /// `books_text` must have `id, book, format, searchable_text`. Plain table, so this is
    /// safe to inspect without the tokenizer.
    private static func hasRequiredTextColumns(_ conn: Connection) -> Bool {
        do {
            let stmt = try conn.prepare("PRAGMA table_info(\"books_text\")")
            defer { stmt.reset() }
            var names = Set<String>()
            while let row = try stmt.failableNext() {
                if let name = row[1] as? String { names.insert(name.lowercased()) }
            }
            return ["id", "book", "format", "searchable_text"].allSatisfy(names.contains)
        } catch {
            log("could not inspect books_text: \(error)")
            return false
        }
    }

    // MARK: - Cancellation (nonisolated: callable from any context)

    nonisolated func beginSearch() -> SearchToken { control.begin() }
    nonisolated func cancel(_ token: SearchToken) { control.cancel(token) }

    // MARK: - Phase 1: ids

    /// Distinct Calibre book ids whose indexed text matches `query`.
    ///
    /// Native mode tries the raw FTS5 expression first and, on a syntax error, retries once
    /// with the sanitized expression (D10). Throws `.cancelled` when `token` went stale.
    func searchBooks(_ query: FTSQuery, token: SearchToken) throws -> FTSBookSet {
        guard control.isCurrent(token) else { throw FTSSearchError.cancelled }
        guard !query.stemmed else { throw FTSSearchError.tokenizerUnavailable }   // M6
        try refreshIfFileChanged()
        let stamp = try currentStamp(token: token)

        switch mode {
        case .likeFallback:
            let ids = try likeScan(query.normalized, token: token)
            return FTSBookSet(bookIDs: ids, stamp: stamp, usedSanitizedFallback: false)
        case .native:
            do {
                let ids = try matchBooks(expression: query.rawMatchExpression, formats: query.formats, token: token)
                return FTSBookSet(bookIDs: ids, stamp: stamp, usedSanitizedFallback: false)
            } catch FTSSearchError.syntax(_) {
                let ids = try matchBooks(expression: query.sanitizedMatchExpression, formats: query.formats, token: token)
                return FTSBookSet(bookIDs: ids, stamp: stamp, usedSanitizedFallback: true)
            }
        }
    }

    private func matchBooks(expression: String, formats: Set<String>?, token: SearchToken) throws -> [Int] {
        var sql = """
            SELECT DISTINCT bt.book
            FROM books_fts
            JOIN books_text AS bt ON bt.id = books_fts.rowid
            WHERE books_fts MATCH ?
            """
        var bindings: [Binding?] = [expression]
        if let formats {
            if formats.isEmpty { return [] }
            let sorted = formats.map { $0.uppercased() }.sorted()
            sql += " AND bt.format IN (" + sorted.map { _ in "?" }.joined(separator: ",") + ")"
            bindings.append(contentsOf: sorted.map { $0 as Binding? })
        }
        let rows = try drain(sql, bindings, token: token)
        return rows.compactMap { ($0[0] as? Int64).map(Int.init) }
    }

    private func likeScan(_ phrase: String, token: SearchToken) throws -> [Int] {
        // Escape LIKE metacharacters so the user's text is matched literally. SQLite LIKE
        // is already ASCII case-insensitive, so no LOWER() is needed.
        let escaped = phrase
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let sql = """
            SELECT DISTINCT book
            FROM books_text
            WHERE searchable_text LIKE ? ESCAPE '\\'
            """
        let rows = try drain(sql, ["%\(escaped)%"], token: token)
        return rows.compactMap { ($0[0] as? Int64).map(Int.init) }
    }

    // MARK: - Phase 2: snippets for one book

    /// One highlighted snippet per matching (book, format) document, best rank first.
    /// Native mode only; `likeFallback` returns an empty array. Per-book queries are the
    /// design (mirrors Calibre's `search_text_in_thread`): do not batch books.
    func snippets(bookID: Int, query: FTSQuery, token: SearchToken,
                  snippetTokens: Int = 64) throws -> [FTSSnippet] {
        guard control.isCurrent(token) else { throw FTSSearchError.cancelled }
        guard !query.stemmed else { throw FTSSearchError.tokenizerUnavailable }   // M6
        try refreshIfFileChanged()
        guard mode == .native else { return [] }

        func run(_ expression: String) throws -> [FTSSnippet] {
            var sql = """
                SELECT bt.id, bt.book, bt.format,
                       snippet(books_fts, 0, ?, ?, '\u{2026}', ?)
                FROM books_fts
                JOIN books_text AS bt ON bt.id = books_fts.rowid
                WHERE bt.book = ? AND books_fts MATCH ?
                """
            // FTS5 caps snippets at 64 tokens.
            let tokenCount = max(1, min(snippetTokens, 64))
            var bindings: [Binding?] = ["\u{1D}", "\u{1D}", Int64(tokenCount), Int64(bookID), expression]
            if let formats = query.formats {
                if formats.isEmpty { return [] }
                let sorted = formats.map { $0.uppercased() }.sorted()
                sql += " AND bt.format IN (" + sorted.map { _ in "?" }.joined(separator: ",") + ")"
                bindings.append(contentsOf: sorted.map { $0 as Binding? })
            }
            sql += " ORDER BY books_fts.rank"
            let rows = try drain(sql, bindings, token: token)
            return rows.compactMap { row -> FTSSnippet? in
                guard let id = (row[0] as? Int64).map(Int.init),
                      let book = (row[1] as? Int64).map(Int.init),
                      let format = row[2] as? String,
                      let text = row[3] as? String else { return nil }
                return FTSSnippet(textRowID: id, bookID: book, format: format, text: text)
            }
        }

        do {
            return try run(query.rawMatchExpression)
        } catch FTSSearchError.syntax(_) {
            return try run(query.sanitizedMatchExpression)
        }
    }

    // MARK: - Index progress

    /// Ambrosia's own derivation: Calibre keeps its left/total counters in memory.
    func indexProgress() throws -> FTSIndexProgress {
        try refreshIfFileChanged()
        let indexed = try scalarInt("SELECT COUNT(*) FROM books_text")
        let queued = try scalarInt("SELECT COUNT(*) FROM dirtied_formats")
        return FTSIndexProgress(indexed: indexed, queued: queued)
    }

    // MARK: - Test hook

    /// Lowers the busy timeout so a test can provoke `.busy` quickly.
    func setBusyTimeoutForTesting(_ seconds: Double) {
        db.busyTimeout = seconds
    }

    // MARK: - File identity (D19)

    /// Reopens the connection when `full-text-search.db` was replaced. Calibre's re-index
    /// deletes the file and recreates it; an open connection would keep reading the
    /// unlinked old file and `PRAGMA data_version` would not change.
    private func refreshIfFileChanged() throws {
        guard let current = Self.fileIdentity(at: ftsURL) else {
            throw FTSSearchError.sqlite(code: SQLITE_CANTOPEN, message: "full-text-search.db is missing")
        }
        guard current != identity else { return }
        // The interruptible handle is detached BEFORE the old connection can be closed.
        control.swap(handle: nil)
        guard let opened = Self.openConnection(ftsURL: ftsURL) else {
            // Keep the old connection object alive but unreachable to interrupts; identity is
            // unchanged, so the next call tries again instead of serving the old file.
            control.swap(handle: db.handle)
            throw FTSSearchError.sqlite(code: SQLITE_CANTOPEN, message: "full-text-search.db could not be reopened")
        }
        db = opened.conn
        identity = opened.identity
        mode = opened.mode
        control.swap(handle: opened.conn.handle)
        Self.log("reopened after file replacement mode=\(opened.mode == .native ? "native" : "likeFallback") reason=\(opened.reason)")
    }

    private func currentStamp(token: SearchToken) throws -> FTSIndexStamp {
        let rows = try drain("PRAGMA data_version", [], token: token)
        let version = (rows.first?[0] as? Int64).map(Int.init) ?? 0
        return FTSIndexStamp(device: identity.device, inode: identity.inode, dataVersion: version)
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
        let path = url.resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    // MARK: - Statement helpers (lock discipline, D20)

    /// Runs one statement to completion and returns every row. No suspension point exists
    /// between `prepare` and the last `step`, and the statement is reset on every exit path
    /// so SQLite's read lock is released. `for row in statement` is never used: its iterator
    /// is `try!`-based and would trap on an interrupt or a busy error.
    private func drain(_ sql: String, _ bindings: [Binding?], token: SearchToken?) throws -> [[Binding?]] {
        do {
            let stmt = try db.prepare(sql, bindings)
            defer { stmt.reset() }
            var rows: [[Binding?]] = []
            while let row = try stmt.failableNext() {
                rows.append(row)
                if rows.count % 256 == 0, let token, !control.isCurrent(token) {
                    throw FTSSearchError.cancelled
                }
            }
            if let token, !control.isCurrent(token) { throw FTSSearchError.cancelled }
            return rows
        } catch {
            throw Self.mapError(error, token: token, control: control)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let rows = try drain(sql, [], token: nil)
        return (rows.first?[0] as? Int64).map(Int.init) ?? 0
    }

    // MARK: - Error mapping

    /// Maps a thrown error to `FTSSearchError`. A stale token wins over any other code: an
    /// interrupted statement reports `SQLITE_INTERRUPT`, but a search that went stale can
    /// also fail some other way on its way out, and either way the caller must see
    /// `.cancelled` and cache nothing.
    static func mapError(_ error: Error, token: SearchToken?, control: SearchControl) -> FTSSearchError {
        if let mapped = error as? FTSSearchError { return mapped }
        if let token, !control.isCurrent(token) { return .cancelled }
        guard let result = error as? SQLite.Result else {
            return .sqlite(code: -1, message: String(describing: error))
        }
        let primary: Int32
        let message: String
        switch result {
        case let .error(msg, code, _):
            primary = code
            message = msg
        case let .extendedError(msg, extendedCode, _):
            primary = extendedCode & 0xFF   // low byte is the primary result code
            message = msg
        }
        switch primary {
        case SQLITE_INTERRUPT:
            return .cancelled
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .busy
        case SQLITE_ERROR where isFTSSyntaxMessage(message):
            return .syntax(message)
        default:
            return .sqlite(code: primary, message: message)
        }
    }

    /// FTS5 reports a bad MATCH expression as a plain `SQLITE_ERROR`. Observed message
    /// shapes (docs/calibre-fts.md, Verification log): `fts5: syntax error near "+"`,
    /// `unterminated string`, `no such column: foo`. Keying on `fts5:` alone would miss two
    /// of the three. A false positive only costs one extra attempt with the sanitized
    /// expression, which then fails again with the real error.
    static func isFTSSyntaxMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.hasPrefix("fts5:")
            || lowered.contains("unterminated string")
            || lowered.contains("no such column")
            || lowered.contains("malformed match expression")
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        #if DEBUG
        print("[CalibreFTSLibrary] \(message)")
        #endif
    }
}
