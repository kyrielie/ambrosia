import Foundation

/// Immutable, flat struct-of-arrays snapshot for high-performance, low-memory
/// autocomplete queries across tens of thousands of tags, authors, or series.
public final class SuggestionSnapshot: Sendable {

    /// Concatenated NFD-folded UTF-8 bytes separated by 0x0A ('\n').
    private let blob: [UInt8]

    /// Start byte offset of each candidate in `blob`.
    private let offsets: [UInt32]

    /// Length in bytes of each candidate in `blob`.
    private let lengths: [UInt16]

    /// Usage count (number of linked books) per candidate.
    private let frequencies: [UInt32]

    /// Compact 1-byte representation of `SuggestionTagType`.
    private let tagTypes: [UInt8]

    /// Original-case display strings.
    private let originalStrings: [String]

    /// Packed first-letter initials of up to 4 tokens for fast integer acronym checks.
    private let packedInitials: [UInt32]

    /// Inverted index mapping folded tokens to candidate row indices.
    private let tokenPostings: [String: [Int32]]

    public init(
        originals: [String],
        frequencies: [Int],
        types: [SuggestionTagType]? = nil
    ) {
        var blobBytes: [UInt8] = []
        var offsetArr: [UInt32] = []
        var lengthArr: [UInt16] = []
        var freqArr: [UInt32] = []
        var typeArr: [UInt8] = []
        var initialsArr: [UInt32] = []
        var postings: [String: [Int32]] = [:]

        blobBytes.reserveCapacity(originals.count * 16)
        offsetArr.reserveCapacity(originals.count)
        lengthArr.reserveCapacity(originals.count)
        freqArr.reserveCapacity(originals.count)
        typeArr.reserveCapacity(originals.count)
        initialsArr.reserveCapacity(originals.count)

        for (index, original) in originals.enumerated() {
            let folded = SuggestionNormalizer.fold(original)
            let foldedBytes = Array(folded.utf8)

            let startOffset = UInt32(blobBytes.count)
            offsetArr.append(startOffset)
            lengthArr.append(UInt16(min(Int(UInt16.max), foldedBytes.count)))
            blobBytes.append(contentsOf: foldedBytes)
            blobBytes.append(0x0A) // separator

            let freqVal = index < frequencies.count ? max(1, frequencies[index]) : 1
            freqArr.append(UInt32(min(Int(UInt32.max), freqVal)))

            let typeVal = (types != nil && index < types?.count ?? 0) ? (types?[index] ?? .unknown).rawValue : 0
            typeArr.append(typeVal)

            // Acronym initials
            let tokens = SuggestionNormalizer.tokens(of: folded)
            var packed: UInt32 = 0
            for (tokenIdx, token) in tokens.prefix(4).enumerated() {
                if let firstByte = token.utf8.first {
                    packed |= (UInt32(firstByte) << (tokenIdx * 8))
                }
            }
            initialsArr.append(packed)

            // Inverted index
            for token in tokens where token.count >= 2 {
                postings[token, default: []].append(Int32(index))
            }
        }

        self.blob = blobBytes
        self.offsets = offsetArr
        self.lengths = lengthArr
        self.frequencies = freqArr
        self.tagTypes = typeArr
        self.originalStrings = originals
        self.packedInitials = initialsArr
        self.tokenPostings = postings
    }

    public var count: Int {
        originalStrings.count
    }

    /// Searches the snapshot using the multi-tier ranking pipeline.
    public func search(query rawQuery: String, limit: Int = 8) -> [SuggestionMatch] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var collector = SuggestionCollector(limit: limit)
        let foldedQuery = SuggestionNormalizer.fold(trimmed)
        let queryTokens = SuggestionNormalizer.tokens(of: foldedQuery)
        let relQuery = RelationshipQuery.parse(trimmed)

        // Tier 1: Substring, prefix, and word-prefix matches via blob search
        searchSubstrings(
            foldedQuery: foldedQuery,
            queryTokens: queryTokens,
            collector: &collector
        )

        // Tier 2: Acronym matching (e.g. "au" -> "alternate universe")
        if !collector.isFull && queryTokens.count == 1 && foldedQuery.count >= 2 && foldedQuery.count <= 4 {
            searchAcronyms(foldedQuery: foldedQuery, collector: &collector)
        }

        // Tier 3: Relationship / Token-Set permutation matching
        if !collector.isFull {
            searchRelationshipPermutations(relQuery: relQuery, queryTokens: queryTokens, collector: &collector)
        }

        // Tier 4: Fuzzy typo matching on token vocabulary
        if !collector.isFull && !queryTokens.isEmpty {
            searchFuzzyVocabulary(queryTokens: queryTokens, relQuery: relQuery, collector: &collector)
        }

        return collector.finalized()
    }

    // MARK: - Search Tiers

    private func searchSubstrings(
        foldedQuery: String,
        queryTokens: [String],
        collector: inout SuggestionCollector
    ) {
        let queryBytes = Array(foldedQuery.utf8)
        guard !queryBytes.isEmpty else { return }

        var searchIndex = 0
        let blobLen = blob.count
        let qLen = queryBytes.count

        while searchIndex + qLen <= blobLen {
            guard let matchOffset = findByteSequence(pattern: queryBytes, in: blob, from: searchIndex) else {
                break
            }

            let candidateIndex = findCandidateIndex(forOffset: matchOffset)
            if candidateIndex >= 0 && candidateIndex < originalStrings.count {
                let candStart = Int(offsets[candidateIndex])
                let candLen = Int(lengths[candidateIndex])
                let isExact = (matchOffset == candStart && qLen == candLen)
                let isPrefix = (matchOffset == candStart)

                let matchClass: SuggestionMatchClass
                if isExact {
                    matchClass = .exact
                } else if isPrefix {
                    matchClass = .prefix
                } else if matchOffset > candStart && (blob[matchOffset - 1] == 0x20 || blob[matchOffset - 1] == 0x2F) {
                    matchClass = .wordPrefix
                } else {
                    matchClass = .substring
                }

                let tagType = SuggestionTagType(rawValue: tagTypes[candidateIndex])
                let foldedStr = String(bytes: blob[candStart..<(candStart + candLen)], encoding: .utf8) ?? ""
                collector.insert(SuggestionMatch(
                    value: originalStrings[candidateIndex],
                    matchClass: matchClass,
                    tagType: tagType,
                    frequency: Int(frequencies[candidateIndex]),
                    foldedName: foldedStr
                ))
            }

            searchIndex = matchOffset + 1
        }
    }

    private func searchAcronyms(foldedQuery: String, collector: inout SuggestionCollector) {
        var expectedPacked: UInt32 = 0
        for (idx, byte) in foldedQuery.utf8.prefix(4).enumerated() {
            expectedPacked |= (UInt32(byte) << (idx * 8))
        }

        for idx in 0..<packedInitials.count where packedInitials[idx] == expectedPacked {
            let tagType = SuggestionTagType(rawValue: tagTypes[idx])
            collector.insert(SuggestionMatch(
                value: originalStrings[idx],
                matchClass: .acronym,
                tagType: tagType,
                frequency: Int(frequencies[idx])
            ))
        }
    }

    private func searchRelationshipPermutations(
        relQuery: RelationshipQuery,
        queryTokens: [String],
        collector: inout SuggestionCollector
    ) {
        guard !queryTokens.isEmpty else { return }

        // Find intersection of postings for candidate generation
        var candidateSet: Set<Int32>?
        for token in queryTokens {
            let postings = tokenPostings[token] ?? []
            if let existing = candidateSet {
                candidateSet = existing.intersection(postings)
            } else {
                candidateSet = Set(postings)
            }
        }

        let candidatesToCheck = candidateSet ?? Set()
        for candIdx32 in candidatesToCheck {
            let candIdx = Int(candIdx32)
            let original = originalStrings[candIdx]
            let (matches, maxDist) = relQuery.matches(candidateName: original, allowTypos: false)
            if matches {
                let tagType = SuggestionTagType(rawValue: tagTypes[candIdx])
                let matchClass: SuggestionMatchClass = (maxDist == 0) ? .relationshipPermuted : .fuzzyDistance1
                collector.insert(SuggestionMatch(
                    value: original,
                    matchClass: matchClass,
                    tagType: tagType,
                    frequency: Int(frequencies[candIdx])
                ))
            }
        }
    }

    private func searchFuzzyVocabulary(
        queryTokens: [String],
        relQuery: RelationshipQuery,
        collector: inout SuggestionCollector
    ) {
        var expandedCandidates = Set<Int32>()

        for qToken in queryTokens where qToken.count >= 4 {
            let maxDist = TypoDistance.maxDistance(forQueryLength: qToken.count)
            guard maxDist > 0 else { continue }

            for (vocabToken, postings) in tokenPostings {
                let dist = TypoDistance.prefixDistance(query: qToken, candidate: vocabToken, maxDistance: maxDist)
                if dist <= maxDist {
                    expandedCandidates.formUnion(postings)
                }
            }
        }

        for candIdx32 in expandedCandidates {
            let candIdx = Int(candIdx32)
            let original = originalStrings[candIdx]
            let (matches, maxDist) = relQuery.matches(candidateName: original, allowTypos: true)
            if matches && maxDist > 0 {
                let matchClass: SuggestionMatchClass = (maxDist == 1) ? .fuzzyDistance1 : .fuzzyDistance2
                let tagType = SuggestionTagType(rawValue: tagTypes[candIdx])
                collector.insert(SuggestionMatch(
                    value: original,
                    matchClass: matchClass,
                    tagType: tagType,
                    frequency: Int(frequencies[candIdx])
                ))
            }
        }
    }

    // MARK: - Helpers

    private func findCandidateIndex(forOffset offset: Int) -> Int {
        var low = 0
        var high = offsets.count - 1
        var answer = 0

        while low <= high {
            let mid = (low + high) / 2
            if offsets[mid] <= UInt32(offset) {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private func findByteSequence(pattern: [UInt8], in buffer: [UInt8], from startIndex: Int) -> Int? {
        let pLen = pattern.count
        let bLen = buffer.count
        guard pLen > 0, startIndex + pLen <= bLen else { return nil }

        let first = pattern[0]
        var index = startIndex
        let lastPossible = bLen - pLen

        while index <= lastPossible {
            if buffer[index] == first {
                var match = true
                for idx in 1..<pLen where buffer[index + idx] != pattern[idx] {
                    match = false
                    break
                }
                if match { return index }
            }
            index += 1
        }
        return nil
    }
}
