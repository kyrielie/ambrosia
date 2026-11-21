import Foundation

/// Pure-logic normalizer for search suggestion queries and candidate indexing.
/// Provides Unicode NFD diacritic stripping, lowercase folding, non-alphanumeric
/// tokenization, and trailing qualifier extraction.
public enum SuggestionNormalizer {

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

    /// Splits a string into normalized alphanumeric tokens, stripping punctuation.
    /// E.g. `James "Bucky" Barnes/Steve Rogers` -> `["james", "bucky", "barnes", "steve", "rogers"]`.
    public static func tokens(of string: String) -> [String] {
        let folded = fold(string)
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
