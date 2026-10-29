// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure extraction logic for locating multiple occurrences of FTS search terms in a book's
/// `searchable_text` and creating windowed, highlighted snippets.
enum FTSOccurrenceExtractor {

    /// Extracts clean search terms and phrases from an FTS query.
    /// Handles quoted phrases (`"slow burn"` -> `"slow burn"`), splits plain terms,
    /// strips trailing wildcards (`magic*` -> `magic`), and filters FTS5 boolean operators.
    static func extractSearchTerms(from query: FTSQuery) -> [String] {
        let text = query.normalized
        var terms: [String] = []
        var inQuote = false
        var current = ""

        for char in text {
            if char == "\"" {
                if inQuote {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        terms.append(trimmed)
                    }
                    current = ""
                    inQuote = false
                } else {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        terms.append(contentsOf: splitPlainTerms(trimmed))
                    }
                    current = ""
                    inQuote = true
                }
            } else {
                current.append(char)
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            if inQuote {
                terms.append(remaining)
            } else {
                terms.append(contentsOf: splitPlainTerms(remaining))
            }
        }

        var seen = Set<String>()
        return terms.compactMap { term -> String? in
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let lower = cleaned.lowercased()
            guard !seen.contains(lower) else { return nil }
            seen.insert(lower)
            return cleaned
        }
    }

    private static let booleanKeywords: Set<String> = ["and", "or", "not", "near"]

    private static func splitPlainTerms(_ string: String) -> [String] {
        string
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "*()^")) }
            .filter { token in
                !token.isEmpty && !booleanKeywords.contains(token.lowercased())
            }
    }

    /// Extracts up to `maxSnippets` occurrence snippets from `text`.
    static func extract(
        text: String,
        textRowID: Int,
        bookID: Int,
        format: String,
        query: FTSQuery,
        maxSnippets: Int = 5,
        radiusCharacters: Int = 120
    ) -> FTSMultiSnippetResult {
        let terms = extractSearchTerms(from: query)
        guard !terms.isEmpty, !text.isEmpty else {
            return FTSMultiSnippetResult(
                textRowID: textRowID,
                bookID: bookID,
                format: format,
                totalOccurrences: 0,
                snippets: []
            )
        }

        // 1. Locate all matches for all terms
        var allRanges: [Range<String.Index>] = []
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                allRanges.append(match)
                searchStart = match.upperBound
            }
        }

        allRanges.sort { $0.lowerBound < $1.lowerBound }

        // 2. Merge overlapping or immediately adjacent ranges
        var uniqueRanges: [Range<String.Index>] = []
        for matchRange in allRanges {
            if let last = uniqueRanges.last, last.overlaps(matchRange) || last.upperBound == matchRange.lowerBound {
                uniqueRanges[uniqueRanges.count - 1] = last.lowerBound..<max(last.upperBound, matchRange.upperBound)
            } else {
                uniqueRanges.append(matchRange)
            }
        }

        let totalOccurrences = uniqueRanges.count
        guard totalOccurrences > 0 else {
            return FTSMultiSnippetResult(
                textRowID: textRowID,
                bookID: bookID,
                format: format,
                totalOccurrences: 0,
                snippets: []
            )
        }

        // 3. Select up to maxSnippets occurrences
        let selectedRanges = Array(uniqueRanges.prefix(max(1, maxSnippets)))

        // 4. Create windowed snippet for each selected range
        var snippets: [FTSOccurrenceSnippet] = []
        for (index, matchRange) in selectedRanges.enumerated() {
            let utf16Offset = matchRange.lowerBound.utf16Offset(in: text)
            let percent = text.isEmpty ? 0.0 : Double(utf16Offset) / Double(max(1, text.utf16.count))

            let windowStartIndex = text.index(matchRange.lowerBound, offsetBy: -radiusCharacters, limitedBy: text.startIndex) ?? text.startIndex
            let windowEndIndex = text.index(matchRange.upperBound, offsetBy: radiusCharacters, limitedBy: text.endIndex) ?? text.endIndex

            var effectiveStart = windowStartIndex
            if effectiveStart > text.startIndex {
                if let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: effectiveStart..<matchRange.lowerBound) {
                    effectiveStart = space.upperBound
                }
            }

            var effectiveEnd = windowEndIndex
            if effectiveEnd < text.endIndex {
                if let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: matchRange.upperBound..<effectiveEnd) {
                    effectiveEnd = space.lowerBound
                }
            }

            var snippetContent = String(text[effectiveStart..<effectiveEnd])

            // Highlight all term matches inside snippetContent, replacing from back to front
            var termRangesInSnippet: [Range<String.Index>] = []
            for term in terms {
                var pos = snippetContent.startIndex
                while pos < snippetContent.endIndex,
                      let hit = snippetContent.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: pos..<snippetContent.endIndex) {
                    termRangesInSnippet.append(hit)
                    pos = hit.upperBound
                }
            }

            termRangesInSnippet.sort { $0.lowerBound < $1.lowerBound }
            var mergedSnippetHits: [Range<String.Index>] = []
            for hit in termRangesInSnippet {
                if let last = mergedSnippetHits.last, last.overlaps(hit) || last.upperBound == hit.lowerBound {
                    mergedSnippetHits[mergedSnippetHits.count - 1] = last.lowerBound..<max(last.upperBound, hit.upperBound)
                } else {
                    mergedSnippetHits.append(hit)
                }
            }

            for hit in mergedSnippetHits.reversed() {
                let matchedText = String(snippetContent[hit])
                snippetContent.replaceSubrange(hit, with: "\u{1D}\(matchedText)\u{1D}")
            }

            var formatted = snippetContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if effectiveStart > text.startIndex {
                formatted = "…" + formatted
            }
            if effectiveEnd < text.endIndex {
                formatted += "…"
            }

            snippets.append(
                FTSOccurrenceSnippet(
                    id: index,
                    charOffset: utf16Offset,
                    text: formatted,
                    approximatePercent: percent
                )
            )
        }

        return FTSMultiSnippetResult(
            textRowID: textRowID,
            bookID: bookID,
            format: format,
            totalOccurrences: totalOccurrences,
            snippets: snippets
        )
    }
}
