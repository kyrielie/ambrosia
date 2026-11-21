import Foundation

/// Fast, allocation-efficient Optimal String Alignment (Damerau-Levenshtein) calculator
/// with early exit and prefix-tolerant comparison for autocomplete suggestions.
public enum TypoDistance {

    /// Adaptive maximum typo edit distance based on query token length:
    /// - Length <= 3: 0 (exact / prefix match only to avoid short noise like 'ang')
    /// - Length 4...6: 1 edit (single insertion, deletion, transposition, or substitution)
    /// - Length >= 7: 2 edits
    public static func maxDistance(forQueryLength length: Int) -> Int {
        if length <= 3 { return 0 }
        if length <= 6 { return 1 }
        return 2
    }

    /// Computes the Optimal String Alignment (OSA) distance between two strings,
    /// bounded by `maxDistance`. Returns `maxDistance + 1` if the true distance exceeds it.
    public static func distance(_ s1: String, _ s2: String, maxDistance: Int = 2) -> Int {
        if s1 == s2 { return 0 }
        let sourceChars = Array(s1.utf8)
        let targetChars = Array(s2.utf8)
        return distance(sourceChars: sourceChars, targetChars: targetChars, maxDistance: maxDistance)
    }

    /// UTF-8 byte slice variant for maximum inner loop performance without String decoding.
    public static func distance(
        sourceChars: [UInt8],
        targetChars: [UInt8],
        maxDistance: Int = 2
    ) -> Int {
        let sourceLength = sourceChars.count
        let targetLength = targetChars.count

        if abs(sourceLength - targetLength) > maxDistance { return maxDistance + 1 }
        if sourceLength == 0 { return targetLength }
        if targetLength == 0 { return sourceLength }

        // Distance matrix of size (sourceLength + 1) * (targetLength + 1)
        let stride = targetLength + 1
        var matrix = Array(repeating: 0, count: (sourceLength + 1) * stride)

        for rowIdx in 0...sourceLength {
            matrix[rowIdx * stride] = rowIdx
        }
        for colIdx in 0...targetLength {
            matrix[colIdx] = colIdx
        }

        for rowIdx in 1...sourceLength {
            var minInRow = Int.max
            let rowOffset = rowIdx * stride
            let prevRowOffset = (rowIdx - 1) * stride
            let prevPrevRowOffset = (rowIdx - 2) * stride

            for colIdx in 1...targetLength {
                let cost = sourceChars[rowIdx - 1] == targetChars[colIdx - 1] ? 0 : 1
                var val = min(
                    matrix[prevRowOffset + colIdx] + 1,          // deletion
                    matrix[rowOffset + (colIdx - 1)] + 1,        // insertion
                    matrix[prevRowOffset + (colIdx - 1)] + cost   // substitution
                )

                // Transposition check (OSA)
                if rowIdx > 1 && colIdx > 1 &&
                    sourceChars[rowIdx - 1] == targetChars[colIdx - 2] &&
                    sourceChars[rowIdx - 2] == targetChars[colIdx - 1] {
                    val = min(val, matrix[prevPrevRowOffset + (colIdx - 2)] + 1)
                }

                matrix[rowOffset + colIdx] = val
                minInRow = min(minInRow, val)
            }

            if minInRow > maxDistance {
                return maxDistance + 1
            }
        }

        let result = matrix[sourceLength * stride + targetLength]
        return result <= maxDistance ? result : maxDistance + 1
    }

    /// Tests if `queryToken` matches a prefix of `candidateToken` within `maxDistance`.
    /// Autocomplete users often type partial tokens with a typo (e.g. 'enemise' for 'enemies to lovers').
    public static func prefixDistance(
        query: String,
        candidate: String,
        maxDistance: Int = 2
    ) -> Int {
        if candidate.hasPrefix(query) { return 0 }
        let queryBytes = Array(query.utf8)
        let candidateBytes = Array(candidate.utf8)
        let qLen = queryBytes.count
        let cLen = candidateBytes.count

        if qLen <= 3 {
            // For short tokens, require exact prefix
            return candidate.hasPrefix(query) ? 0 : maxDistance + 1
        }

        // Compare query against candidate prefixes of length (qLen - maxDistance) ... min(cLen, qLen + maxDistance)
        let minPref = max(1, qLen - maxDistance)
        let maxPref = min(cLen, qLen + maxDistance)
        guard minPref <= maxPref else { return maxDistance + 1 }

        var best = maxDistance + 1
        for prefLen in minPref...maxPref {
            let prefBytes = Array(candidateBytes[0..<prefLen])
            let dist = distance(sourceChars: queryBytes, targetChars: prefBytes, maxDistance: maxDistance)
            if dist < best {
                best = dist
                if best == 0 { break }
            }
        }
        return best
    }
}
