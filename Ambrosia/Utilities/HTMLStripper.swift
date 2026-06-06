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
