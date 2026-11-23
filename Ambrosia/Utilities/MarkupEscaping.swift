import Foundation

/// Shared markup escaping. Previously six private copies of these two
/// functions existed (feeds, OPML, reader, series gap report, EPUB builders).

/// Escapes `&`, `<`, `>` and `"` for XML or HTML text and attribute values.
/// `&` is replaced first so the other entities are not double-escaped.
func xmlEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Same as `xmlEscape(_:)` and additionally escapes `'` as `&apos;`.
/// Used by the EPUB builders, whose XHTML and OPF output escapes apostrophes.
func xmlEscapeIncludingApostrophe(_ string: String) -> String {
    xmlEscape(string).replacingOccurrences(of: "'", with: "&apos;")
}
