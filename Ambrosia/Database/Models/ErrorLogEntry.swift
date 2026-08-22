import Foundation

/// A single persisted failure record, written by `AmbrosiaMetaDB.logError`.
/// Value type — read back from `error_log`, never held as live state.
///
/// This is the durable counterpart to the `#if DEBUG print` statements used
/// elsewhere in the app (see docs/overview.md's Invariant 13): those are
/// fine for development, but leave no trail once a release build is running
/// in the field. `error_log` gives failures in AO3 extraction, EPUB
/// parsing, and `LocalFeedServer` routes (none of which had any durable
/// diagnostic trail before this) a queryable, prunable record, viewable via
/// `ErrorLogView`. Scoped-per-subsystem diagnostics that already exist
/// (`ao3_extraction_diagnostics`) are unaffected — this is a general-purpose
/// complement, not a replacement.
struct ErrorLogEntry: Identifiable, Sendable {
    let id: Int64
    let occurredAt: Date
    /// Short subsystem tag, e.g. "AO3Extraction", "EPUBParser", "LocalFeedServer".
    /// Not an enum: new subsystems shouldn't require a schema/model change,
    /// the same reasoning `ao3_extraction_diagnostics.status` already uses.
    let subsystem: String
    /// Short description of what was being attempted, e.g. "parse OPF", "serve /feed.xml".
    let operation: String
    /// The error's human-readable description (typically `error.localizedDescription`).
    let message: String
    /// Source file the error was logged from, e.g. via `#fileID`. Optional —
    /// some call sites may not have a meaningful one.
    let file: String?
    let line: Int?
    /// The book this error relates to, if any. Nil for library-wide or
    /// non-book-specific failures (e.g. a feed-server route error).
    let calibreID: Int?
}
