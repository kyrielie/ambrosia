import Foundation
import SQLite
import SQLite3

/// Shared housekeeping for the standalone SQLite files Ambrosia maintains
/// (`ambrosia_semantic_passages.db`, `full-text-search.db`). Previously
/// duplicated in `PassageDatabase` and `CalibreFTSWriter`.
enum SQLiteFileMaintenance {

    /// Returns true when a SQLite result code represents database corruption or
    /// a non-database header (`SQLITE_CORRUPT` or `SQLITE_NOTADB`), masking off
    /// extended error bits.
    static func isCorruptionErrorCode(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    /// Removes a derived SQLite database file and its `-wal` and `-shm` sidecars.
    /// Intended strictly for rebuildable derived indexes under Application Support.
    static func removeDatabaseAndSidecars(at baseFileURL: URL) {
        let paths = [
            baseFileURL,
            baseFileURL.deletingPathExtension().appendingPathExtension("db-wal"),
            baseFileURL.deletingPathExtension().appendingPathExtension("db-shm")
        ]
        let fm = FileManager.default
        for path in paths {
            try? fm.removeItem(at: path)
        }
    }

    /// Combined on-disk size of a database file plus its `-wal` and `-shm`
    /// siblings. Missing files count as zero.
    static func totalFileSize(baseFileURL: URL) -> Int64 {
        var total: Int64 = 0
        let paths = [
            baseFileURL,
            baseFileURL.deletingPathExtension().appendingPathExtension("db-wal"),
            baseFileURL.deletingPathExtension().appendingPathExtension("db-shm")
        ]
        let fm = FileManager.default
        for path in paths {
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    /// Truncates the WAL, vacuums, then truncates the WAL again. Best effort:
    /// individual statement failures are ignored, matching the behavior of the
    /// two call sites this replaced.
    static func checkpointAndVacuum(_ connection: Connection) {
        _ = try? connection.run("PRAGMA wal_checkpoint(TRUNCATE);")
        _ = try? connection.run("VACUUM;")
        _ = try? connection.run("PRAGMA wal_checkpoint(TRUNCATE);")
    }
}
