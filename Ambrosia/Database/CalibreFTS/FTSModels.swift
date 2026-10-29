// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Failure modes of the Calibre FTS layer.
enum FTSSearchError: Error, Sendable, Equatable {
    case cancelled
    case busy
    case syntax(String)
    case tokenizerUnavailable
    case sqlite(code: Int32, message: String)
}

/// Staleness token for one FTS search (Invariant 24). A token is current only until the
/// next `beginSearch()` (or an explicit cancel) bumps the generation.
struct SearchToken: Sendable, Equatable {
    let generation: Int
}

/// Identifies the state of the FTS index a result set was read from (D19).
/// `dataVersion` is only comparable between values taken on the same connection.
struct FTSIndexStamp: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let dataVersion: Int
}

/// Phase 1 result: the distinct Calibre book ids that matched.
struct FTSBookSet: Sendable {
    let bookIDs: [Int]
    let stamp: FTSIndexStamp
    /// True when the user's raw FTS5 syntax failed to parse and the sanitized
    /// AND-of-quoted-terms expression produced this result instead (D10).
    let usedSanitizedFallback: Bool
}

/// Phase 2 result for one (book, format) document.
struct FTSSnippet: Sendable, Equatable {
    /// `books_text.id`. Session-local: Calibre's `INSERT OR REPLACE` gives a re-indexed
    /// document a new id, so never persist this (D22). Address documents by (book, format).
    let textRowID: Int
    let bookID: Int
    let format: String
    /// Contains `\u{1D}` around highlighted terms.
    let text: String
}

/// An individual occurrence snippet within a book's text.
struct FTSOccurrenceSnippet: Identifiable, Sendable, Equatable {
    let id: Int
    let charOffset: Int
    /// Contains `\u{1D}` around highlighted terms.
    let text: String
    /// Approximate progress in the text (0.0 to 1.0).
    let approximatePercent: Double
}

/// Multi-snippet result for one book across all occurrences.
struct FTSMultiSnippetResult: Sendable, Equatable {
    let textRowID: Int
    let bookID: Int
    let format: String
    let totalOccurrences: Int
    let snippets: [FTSOccurrenceSnippet]
}

/// Ambrosia's own derivation of indexing progress. Calibre keeps its left/total counters
/// in memory, so nothing is stored in the database to read back.
struct FTSIndexProgress: Sendable, Equatable {
    let indexed: Int    // COUNT(*) FROM books_text
    let queued: Int     // COUNT(*) FROM dirtied_formats
    var total: Int { indexed + queued }
    var isComplete: Bool { queued == 0 }
    /// Mirrors Calibre's `almost_complete`: fewer than 10 percent still queued.
    var isAlmostComplete: Bool { total == 0 ? false : Double(queued) / Double(total) < 0.1 }
}
