import Foundation
import SQLite

/// Assembles immutable suggestion snapshots off-actor using an independent read-only SQLite connection.
public enum SuggestionSnapshotBuilder {

    /// Opens an independent read-only SQLite connection to `metadata.db` and builds
    /// snapshots for tags, authors, and series.
    public static func buildSnapshots(
        calibreRoot: URL,
        tagTypes: [String: SuggestionTagType] = [:]
    ) throws -> (tags: SuggestionSnapshot, authors: SuggestionSnapshot, series: SuggestionSnapshot) {
        let dbURL = calibreRoot.appendingPathComponent("metadata.db")
        let db = try Connection(dbURL.path, readonly: true)
        db.busyTimeout = 5.0

        // 1. Tags query
        let tagsSQL = """
            SELECT t.name, COUNT(btl.book) AS freq
            FROM tags t
            JOIN books_tags_link btl ON btl.tag = t.id
            GROUP BY t.id
            HAVING freq > 0
            ORDER BY freq DESC
            """
        var tagNames: [String] = []
        var tagFreqs: [Int] = []
        var tagTypeArr: [SuggestionTagType] = []

        for row in try db.prepare(tagsSQL) {
            guard let name = row[0] as? String else { continue }
            let freq = (row[1] as? Int64).map(Int.init) ?? 1
            tagNames.append(name)
            tagFreqs.append(freq)
            tagTypeArr.append(tagTypes[name] ?? .unknown)
        }
        let tagSnapshot = SuggestionSnapshot(originals: tagNames, frequencies: tagFreqs, types: tagTypeArr)

        // 2. Authors query
        let authorsSQL = """
            SELECT a.name, COUNT(bal.book) AS freq
            FROM authors a
            JOIN books_authors_link bal ON bal.author = a.id
            GROUP BY a.id
            HAVING freq > 0
            ORDER BY freq DESC
            """
        var authorNames: [String] = []
        var authorFreqs: [Int] = []

        for row in try db.prepare(authorsSQL) {
            guard let name = row[0] as? String else { continue }
            let freq = (row[1] as? Int64).map(Int.init) ?? 1
            authorNames.append(name)
            authorFreqs.append(freq)
        }
        let authorSnapshot = SuggestionSnapshot(originals: authorNames, frequencies: authorFreqs)

        // 3. Series query
        let seriesSQL = """
            SELECT s.name, COUNT(bsl.book) AS freq
            FROM series s
            JOIN books_series_link bsl ON bsl.series = s.id
            GROUP BY s.id
            HAVING freq > 0
            ORDER BY freq DESC
            """
        var seriesNames: [String] = []
        var seriesFreqs: [Int] = []

        for row in try db.prepare(seriesSQL) {
            guard let name = row[0] as? String else { continue }
            let freq = (row[1] as? Int64).map(Int.init) ?? 1
            seriesNames.append(name)
            seriesFreqs.append(freq)
        }
        let seriesSnapshot = SuggestionSnapshot(originals: seriesNames, frequencies: seriesFreqs)

        return (tags: tagSnapshot, authors: authorSnapshot, series: seriesSnapshot)
    }
}
