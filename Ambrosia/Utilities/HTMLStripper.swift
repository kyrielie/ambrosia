import Foundation

/// Strips HTML tags from a string without touching the main thread.
/// Used during import to pre-compute plain-text versions of HTML fields.
///
/// Strategy:
/// 1. Fast regex strip — handles the common case (AO3 paragraph HTML).
/// 2. Does NOT use NSAttributedString — that requires the main thread
///    and is too slow to call per-book during a background import.
enum HTMLStripper {

    /// Returns plain text with HTML tags removed and entities decoded.
    static func strip(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        // Replace common block tags with newlines before stripping
        var result = html
            .replacingOccurrences(of: "<br>",   with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>",  with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>",   with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>",  with: "\n", options: .caseInsensitive)

        // Strip all remaining tags
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;",   with: "&")
            .replacingOccurrences(of: "&lt;",    with: "<")
            .replacingOccurrences(of: "&gt;",    with: ">")
            .replacingOccurrences(of: "&quot;",  with: "\"")
            .replacingOccurrences(of: "&#39;",   with: "'")
            .replacingOccurrences(of: "&apos;",  with: "'")
            .replacingOccurrences(of: "&nbsp;",  with: " ")
            .replacingOccurrences(of: "&#8203;", with: "") // zero-width space

        // Collapse runs of whitespace/newlines
        result = result
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
