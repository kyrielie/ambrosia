import Foundation

/// Pair of a Calibre book, its associated AO3 metadata (if any), and its series cache entries.
typealias FeedBookPair = (book: CalibreBook, ao3: AO3MetadataRecord?, seriesEntries: [SeriesCacheEntry])

/// A page-resident book, or the series group it anchors (when it leads a
/// >1-member series and grouping is on). Serialization-agnostic — consumed by
/// both the JSON Feed and RSS builders.
enum FeedDisplayUnit {
    case book(FeedBookPair)
    case series(SeriesGroup, members: [FeedBookPair])
}

/// Order-preserving dedup for feed metadata arrays (fandoms, relationships,
/// characters, warnings, categories, freeform tags). Used across all feed formats
/// so every metadata array field goes through the same pass.
func dedupPreservingOrder(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

/// XML character escaping for OPML, RSS, and XML attributes.
func xmlEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Date formatting utilities shared across RSS and JSON feed generation.
enum FeedDateFormatter {
    /// Tries ISO 8601 with fractional seconds, then without, then a bare
    /// yyyy-MM-dd date.
    static func parseFlexibleDate(_ isoString: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: isoString) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: isoString) { return date }
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyy-MM-dd"
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        return fallbackFormatter.date(from: isoString)
    }

    static func rfc822Date(from isoString: String) -> String {
        rfc822Date(from: parseFlexibleDate(isoString) ?? Date.distantPast)
    }

    static func rfc822Date(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func iso8601DateString(from isoString: String) -> String {
        iso8601DateString(from: parseFlexibleDate(isoString) ?? Date.distantPast)
    }

    static func iso8601DateString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// The `series_cache` row to treat as "the series this book is" for read-state
/// identity purposes — distinct from ordinary series *membership* (a normal
/// standalone work that happens to be "Part 3 of Series X"), which must NOT be
/// used to key read-state, since different parts of a series are different
/// works with independent read progress.
///
/// Only relevant when `book.isDescriptionAnthology` is true — i.e. Calibre's
/// EPUB-merge plugin wrote this book's own description, meaning this specific
/// Calibre row is an entire merged series compiled into one file with no single
/// AO3 work URL of its own.
func anthologySeriesEntry(for book: CalibreBook, seriesEntries: [SeriesCacheEntry]) -> SeriesCacheEntry? {
    guard book.isDescriptionAnthology else { return nil }
    let sorted = seriesEntries.sorted { $0.seriesIndex < $1.seriesIndex }
    if sorted.count > 1 {
        print("[LocalFeedServer] anthology book \(book.id) has \(sorted.count) series_cache rows; using \(sorted[0].seriesName)")
    }
    return sorted.first
}
