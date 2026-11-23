import Foundation

/// Pure Swift Level 1 deterministic tag variant normalizer.
///
/// Converts tag variants (different character order in relationships, parenthetical
/// fandom tags, reader aliases, accents, spacing, suffixes) into a canonical key.
/// Used when `matchVariants == true` on first-listed position and relationship count filters.
public enum TagVariantKey {

    private static let parentheticalRegex: NSRegularExpression = {
        // Matches (...)
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\s*\\([^)]*\\)", options: [])
    }()

    private static let ynRegex: NSRegularExpression = {
        // Matches whole-token y/n
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "(?i)(?<=^|[\\s/&,])y/n(?=[\\s/&,]|$)", options: [])
    }()

    private static let leadingImpliedRegex: NSRegularExpression = {
        // Matches leading word "implied"
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^implied\\s+", options: [.caseInsensitive])
    }()

    private static let whitespaceRegex: NSRegularExpression = {
        // Collapses multi-spaces
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\s+", options: [])
    }()

    /// Normalizes a tag to its Level 1 canonical variant key.
    public static func key(for tag: String) -> String {
        // Step 1: Fold case, diacritics, and width
        var text = tag.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)

        // Step 2: Remove straight and curly double quotes, collapse whitespace
        text = text.replacingOccurrences(of: "\"", with: "")
                   .replacingOccurrences(of: "“", with: "")
                   .replacingOccurrences(of: "”", with: "")
        text = whitespaceRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: text.utf16.count),
            withTemplate: " "
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return "" }

        // Step 3: Strip trailing " - relationship"
        if text.hasSuffix(" - relationship") {
            text = String(text.dropLast(" - relationship".count)).trimmingCharacters(in: .whitespaces)
        }

        // Step 4: Strip trailing "| alias" segment ONLY when text after last '|' contains neither '/' nor '&'
        if let lastPipeIndex = text.lastIndex(of: "|") {
            let afterPipe = text[text.index(after: lastPipeIndex)...]
            if !afterPipe.contains("/") && !afterPipe.contains("&") {
                text = String(text[..<lastPipeIndex]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Step 5: Replace glued token "y/n" with "reader"
        text = ynRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: text.utf16.count),
            withTemplate: "reader"
        )

        // Step 6: Determine delimiter class
        enum DelimiterClass {
            case slash
            case ampersand
            case none
        }

        let delimiterClass: DelimiterClass
        let delimiterString: String

        if text.contains("/") {
            delimiterClass = .slash
            delimiterString = "/"
        } else if text.contains("&") {
            delimiterClass = .ampersand
            delimiterString = "&"
        } else if text.contains(" x ") {
            delimiterClass = .slash
            delimiterString = " x "
        } else {
            delimiterClass = .none
            delimiterString = ""
        }

        // Step 7: Delimited tags
        if delimiterClass != .none {
            let rawSides = text.components(separatedBy: delimiterString)
            var normalizedSides: [String] = []

            for side in rawSides {
                var cleanSide = side.trimmingCharacters(in: .whitespaces)
                // Remove parenthetical groups
                cleanSide = parentheticalRegex.stringByReplacingMatches(
                    in: cleanSide,
                    options: [],
                    range: NSRange(location: 0, length: cleanSide.utf16.count),
                    withTemplate: ""
                ).trimmingCharacters(in: .whitespaces)

                // Drop leading word "implied"
                cleanSide = leadingImpliedRegex.stringByReplacingMatches(
                    in: cleanSide,
                    options: [],
                    range: NSRange(location: 0, length: cleanSide.utf16.count),
                    withTemplate: ""
                ).trimmingCharacters(in: .whitespaces)

                // Map reader aliases
                switch cleanSide {
                case "you", "your name", "female reader", "male reader", "fem!reader":
                    cleanSide = "reader"
                default:
                    break
                }

                if !cleanSide.isEmpty {
                    normalizedSides.append(cleanSide)
                }
            }

            normalizedSides.sort()
            let prefix = delimiterClass == .slash ? "/" : "&"
            let joinChar = delimiterClass == .slash ? "/" : "&"
            return "\(prefix)\(normalizedSides.joined(separator: joinChar))"
        }

        // Step 8: Single-sided tags
        var single = text
        single = parentheticalRegex.stringByReplacingMatches(
            in: single,
            options: [],
            range: NSRange(location: 0, length: single.utf16.count),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)

        return single
    }
}
