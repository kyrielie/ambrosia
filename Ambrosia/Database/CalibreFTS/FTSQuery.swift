// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A normalized `fulltext:` query (pure value type, no SQLite).
///
/// The input is tried as raw FTS5 syntax first (`AND`, `OR`, `NEAR`, `prefix*`, `^`),
/// which is what Calibre does. If FTS5 rejects the syntax, callers retry once with
/// `sanitizedMatchExpression`, an implicit AND of quoted terms (D10).
struct FTSQuery: Hashable, Sendable {
    /// Trimmed and NFKC-normalized, nothing else. Calibre NFKC-normalizes queries before
    /// binding them to MATCH. Deliberately not case- or diacritic-folded: with the
    /// `calibre` tokenizer `resume` and `résumé` are different queries (D13).
    let normalized: String
    /// Restrict to these formats (upper-case, as Calibre stores them). `nil` means every
    /// indexed format (D9).
    var formats: Set<String>?
    /// Query `books_fts_stemmed` instead of `books_fts` (M6; unused until then).
    var stemmed: Bool

    private init(normalized: String, formats: Set<String>?, stemmed: Bool) {
        self.normalized = normalized
        self.formats = formats
        self.stemmed = stemmed
    }

    /// Returns nil for input that is empty after trimming.
    static func make(_ input: String, formats: Set<String>? = nil, stemmed: Bool = false) -> FTSQuery? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return FTSQuery(normalized: trimmed.precomposedStringWithCompatibilityMapping,
                        formats: formats, stemmed: stemmed)
    }

    /// Session-cache key (D13). Includes the table choice so stemmed and unstemmed
    /// result sets never collide. Formats are not part of the key because the session
    /// cache is only used for the default all-formats query.
    var cacheKey: String { "\(stemmed ? "s" : "u")|\(normalized)" }

    /// Tried first.
    var rawMatchExpression: String { normalized }

    /// Fallback when the raw expression is a syntax error: every whitespace-separated
    /// piece is wrapped in double quotes (embedded quotes doubled) and the pieces are
    /// joined by a space, which FTS5 reads as AND.
    var sanitizedMatchExpression: String {
        normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }
}
