import Foundation
import NaturalLanguage

/// Reconstructs the full containing sentence around a highlight from its
/// `quotePrefix`, `selectedText`, and `quoteSuffix` using `NLTokenizer(unit: .sentence)`.
enum SentenceContext {

    struct Result: Equatable, Sendable {
        let sentence: String
        let highlightRange: Range<String.Index>?
    }

    static func extract(
        quotePrefix: String,
        selectedText: String,
        quoteSuffix: String
    ) -> Result {
        let trimmedTarget = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else {
            let fallback = (quotePrefix + quoteSuffix).trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(sentence: fallback, highlightRange: nil)
        }

        if quotePrefix.isEmpty && quoteSuffix.isEmpty {
            return Result(sentence: selectedText, highlightRange: selectedText.startIndex..<selectedText.endIndex)
        }

        let combined = quotePrefix + selectedText + quoteSuffix
        let targetStart = combined.index(combined.startIndex, offsetBy: quotePrefix.count)
        let targetEnd = combined.index(targetStart, offsetBy: selectedText.count)

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = combined

        var matchedSentenceRange: Range<String.Index>?
        tokenizer.enumerateTokens(in: combined.startIndex..<combined.endIndex) { range, _ in
            if range.lowerBound <= targetStart && range.upperBound >= targetEnd {
                matchedSentenceRange = range
                return false
            }
            if range.overlaps(targetStart..<targetEnd) {
                matchedSentenceRange = matchedSentenceRange.map {
                    min($0.lowerBound, range.lowerBound)..<max($0.upperBound, range.upperBound)
                } ?? range
            }
            return true
        }

        guard let sRange = matchedSentenceRange else {
            return Result(sentence: combined.trimmingCharacters(in: .whitespacesAndNewlines), highlightRange: nil)
        }

        let rawSentence = String(combined[sRange])
        let leadingTrimCount = rawSentence.prefix(while: { $0.isWhitespace || $0.isNewline }).count
        let trimmedSentence = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)

        let startDist = combined.distance(from: sRange.lowerBound, to: targetStart) - leadingTrimCount
        let endDist = combined.distance(from: sRange.lowerBound, to: targetEnd) - leadingTrimCount

        if startDist >= 0, endDist >= startDist, endDist <= trimmedSentence.count {
            let hlStart = trimmedSentence.index(trimmedSentence.startIndex, offsetBy: startDist)
            let hlEnd = trimmedSentence.index(trimmedSentence.startIndex, offsetBy: endDist)
            return Result(sentence: trimmedSentence, highlightRange: hlStart..<hlEnd)
        }

        return Result(sentence: trimmedSentence, highlightRange: nil)
    }
}
