import Foundation

/// Strips HTML tags from a string without touching the main thread.
/// Used during import to pre-compute plain-text versions of HTML fields.
///
/// Strategy:
/// 1. Fast regex strip — handles the common case (AO3 paragraph HTML).
/// 2. Does NOT use NSAttributedString — that requires the main thread
///    and is too slow to call per-book during a background import.
enum HTMLStripper {

    /// Caches stripped output keyed by the raw HTML input. `CalibreBook` is a
    /// plain struct with no stored cache slot of its own (see its header
    /// comment — "no SwiftData, no faulting"), so `displayComment` and
    /// `isDescriptionAnthology` are computed properties that would otherwise
    /// redo this multi-regex strip on every access: once per row every time
    /// it scrolls back into view in a SwiftUI `List` (rows are destroyed and
    /// recreated, not just hidden), and once per book on every
    /// `LibraryVisibilityPolicy.filter(_ books:)` pass when the
    /// anthology-hiding toggle is on. NSCache is thread-safe and evicts under
    /// memory pressure, so this is safe to hit from both the main-actor UI
    /// path and CalibreLibrary's background query path.
    private static let cache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 2_000 // generous relative to a typical library page/session
        return c
    }()

    /// Returns plain text with HTML tags removed and entities decoded.
    static func strip(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        let key = html as NSString
        if let cached = cache.object(forKey: key) {
            return cached as String
        }

        // Replace common block tags with newlines before stripping
        var result = html
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)

        // Strip all remaining tags
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#8203;", with: "") // zero-width space

        // Collapse runs of whitespace/newlines
        result = result
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cache.setObject(result as NSString, forKey: key)
        return result
    }
}

/// Single source of truth for detecting Calibre EPUB-merge-plugin anthology comments.
/// Used by both `CalibreBook.isDescriptionAnthology` (already HTML-stripped, single book)
/// and `CalibreLibrary.anthologyBookIDs()` (raw HTML from a SQL prefilter, many books),
/// so the two checks can never drift apart again.
enum AnthologyDetector {

    /// True if `strippedComment` (already run through `HTMLStripper.strip`) is an
    /// anthology/merge comment written by Calibre's EPUB-merge plugin.
    /// Deliberately an exact prefix match (not a loose "contains 'anthology'" check)
    /// to avoid misfiring on real works whose own description happens to mention
    /// the word "anthology".
    static func isAnthology(strippedComment: String) -> Bool {
        guard !strippedComment.isEmpty else { return false }
        let trimmed = strippedComment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "Anthology containing:", options: [.caseInsensitive, .anchored]) != nil
    }

    /// Convenience for callers holding raw (unstripped) HTML comment text.
    static func isAnthology(rawComment: String) -> Bool {
        isAnthology(strippedComment: HTMLStripper.strip(rawComment))
    }
}
