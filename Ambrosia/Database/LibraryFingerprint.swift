import Foundation

/// Cheap summary of "has Calibre's library changed since we last scanned it".
/// Stored in `library_state` (see `LibraryStateKey`) and compared on open so the
/// per-launch scans (series cache seed, extraction scan) can be skipped when
/// nothing changed.
///
/// Components, all readable without scanning book files:
/// - `metadata.db` modification time and size
/// - book count, max book id (catches adds and deletes)
/// - max `books.last_modified` (catches edits, if Calibre bumps it; this is
///   an assumption, not verified, see `docs/calibre-library.md`)
///
/// Pure value type so the comparison is testable without a database.
struct LibraryFingerprint: Codable, Equatable {
    /// Bump when the set of components changes so older stored values are ignored.
    static let currentVersion = 1

    var version: Int = LibraryFingerprint.currentVersion
    /// `metadata.db` modification time, whole seconds since 1970.
    var fileModified: Int
    var fileSize: Int
    var bookCount: Int
    var maxBookID: Int
    var maxLastModified: String

    /// JSON with sorted keys, so equal fingerprints encode identically.
    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Nil for a missing value, undecodable text, or a different `version`.
    static func decode(_ text: String?) -> LibraryFingerprint? {
        guard let text, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(LibraryFingerprint.self, from: data),
              value.version == currentVersion else { return nil }
        return value
    }

    /// True only when a stored fingerprint exists and equals `current`.
    /// A missing stored value always means "changed", so a first launch scans.
    static func isUnchanged(stored: LibraryFingerprint?, current: LibraryFingerprint) -> Bool {
        guard let stored else { return false }
        return stored == current
    }
}

/// How the library differs from the last fingerprint this session saw.
enum LibraryChange: Equatable {
    /// Every component equal. Nothing to do.
    case none
    /// Only file mtime or size moved (Calibre rewrote the file, for example
    /// preferences or a series-only edit that leaves `last_modified` alone).
    /// Caches are dropped and the scans re-run, but the visible book set is
    /// not known to differ, so no reload is requested.
    case fileOnly
    /// Book count, max id or max `last_modified` moved: books were added,
    /// removed or edited.
    case content

    /// `known` nil (nothing seen yet this session) is `.none`: the launch
    /// scans compare against the persisted markers themselves.
    static func classify(known: LibraryFingerprint?, current: LibraryFingerprint) -> LibraryChange {
        guard let known else { return .none }
        if known == current { return .none }
        if known.bookCount != current.bookCount
            || known.maxBookID != current.maxBookID
            || known.maxLastModified != current.maxLastModified {
            return .content
        }
        return .fileOnly
    }
}

/// Keys in `library_state`.
enum LibraryStateKey {
    /// Fingerprint the Calibre series cache seed last completed for. Cleared by
    /// any write that rewrites a book's `series_cache` rows (AO3 extraction),
    /// because that deletes a book's Calibre fallback row and only a re-seed
    /// restores it.
    static let seriesSeedFingerprint = "series_seed_fingerprint"
    /// Fingerprint an AO3 extraction scan last finished completely for (nothing
    /// left to extract). Not stored for an interrupted run.
    static let extractionScanFingerprint = "extraction_scan_fingerprint"
}
