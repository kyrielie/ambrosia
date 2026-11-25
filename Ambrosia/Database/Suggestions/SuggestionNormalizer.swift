import Foundation

/// Pure-logic normalizer for search suggestion queries and candidate indexing.
/// Provides Unicode NFD diacritic stripping, lowercase folding, non-alphanumeric
/// tokenization, reader token canonicalization, and qualifier extraction.
public enum SuggestionNormalizer {

    private static let parentheticalRegex: NSRegularExpression = {
        // Matches (...)
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\s*\\([^)]*\\)", options: [])
    }()

    private static let ynRegex: NSRegularExpression = {
        // Matches y/n as whole token or surrounded by whitespace/punctuation
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "(?i)(?<=^|[\\s/&,])y/n(?=[\\s/&,]|$)|(?i)\\by/n\\b", options: [])
    }()

    /// Normalizes a string by decomposing Unicode canonical mappings (NFD),
    /// stripping non-spacing combining marks (e.g. accents), and converting to lowercase.
    /// E.g. "Padmé" -> "padme", "RÉSUMÉ" -> "resume".
    public static func fold(_ string: String) -> String {
        let nfd = string.decomposedStringWithCanonicalMapping
        let stripped = nfd.unicodeScalars.filter { scalar in
            !CharacterSet.nonBaseCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped)).lowercased()
    }

    /// Canonicalizes reader tokens: replaces `y/n` with `reader`.
    public static func normalizeReaderTokens(_ string: String) -> String {
        ynRegex.stringByReplacingMatches(
            in: string,
            options: [],
            range: NSRange(location: 0, length: string.utf16.count),
            withTemplate: "reader"
        )
    }

    /// Strips any parenthetical qualifiers, e.g. `(Smallville)` or `(Marvel)`.
    public static func stripParentheticals(_ string: String) -> String {
        parentheticalRegex.stringByReplacingMatches(
            in: string,
            options: [],
            range: NSRange(location: 0, length: string.utf16.count),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Splits a string into normalized alphanumeric tokens, stripping punctuation and quotes.
    /// Canonicalizes `y/n` into `reader`.
    /// E.g. `James "Bucky" Barnes/Steve Rogers` -> `["james", "bucky", "barnes", "steve", "rogers"]`.
    public static func tokens(of string: String) -> [String] {
        let withReader = normalizeReaderTokens(string)
        let folded = fold(withReader)
        return folded.unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .compactMap { sub in
                let str = String(String.UnicodeScalarView(sub))
                return str.isEmpty ? nil : str
            }
    }

    /// Extracts a trailing parenthetical qualifier if present (e.g. fandom tag qualification).
    /// E.g. `"Aziraphale/Crowley (Good Omens)"` -> `(base: "Aziraphale/Crowley", qualifier: "Good Omens")`.
    public static func stripTrailingQualifier(_ string: String) -> (base: String, qualifier: String?) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let openParenIndex = trimmed.lastIndex(of: "(") else {
            return (trimmed, nil)
        }
        let basePart = trimmed[..<openParenIndex].trimmingCharacters(in: .whitespaces)
        let qualStart = trimmed.index(after: openParenIndex)
        let qualEnd = trimmed.index(before: trimmed.endIndex)
        let qualifier = String(trimmed[qualStart..<qualEnd]).trimmingCharacters(in: .whitespaces)
        return (basePart, qualifier.isEmpty ? nil : qualifier)
    }

    /// Tests if a character is an explicit entity relationship separator:
    /// `/`, `&`, `+`, `|`, `,`.
    public static func isRelationshipSeparator(_ char: Character) -> Bool {
        char == "/" || char == "&" || char == "+" || char == "|" || char == ","
    }
}
