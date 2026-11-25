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

    /// Sorted unique vocabulary tokens for fast binary-search prefix expansion.
    private let sortedTokens: [String]

    /// Inverted index mapping entity initials and single letters to candidate row indices.
    private let initialsPostings: [String: [Int32]]

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
        var initPostings: [String: [Int32]] = [:]

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

            // Inverted index for complete tokens
            for token in tokens where token.count >= 2 {
                postings[token, default: []].append(Int32(index))
            }

            // Entity initials for relationship candidates
            let hasSeparator = folded.contains("/") || folded.contains("&") || folded.contains(" x ")
            if hasSeparator {
                let entities = RelationshipQuery.splitEntities(folded)
                var candidateKeys = Set<String>()

                for entity in entities {
                    let eTokens = SuggestionNormalizer.tokens(of: entity)
                    guard !eTokens.isEmpty else { continue }

                    // Individual first letters of each token in the entity
                    for eToken in eTokens {
                        if let firstLetter = eToken.first {
                            candidateKeys.insert(String(firstLetter))
                        }
                    }

                    // Combined initials across the entity
                    let allInit = eTokens.compactMap { $0.first.map(String.init) }.joined()
                    if allInit.count >= 2 && allInit.count <= 4 {
                        candidateKeys.insert(allInit)
                    }

                    // First-last initials
                    if eTokens.count >= 2,
                       let first = eTokens.first?.first,
                       let last = eTokens.last?.first {
                        candidateKeys.insert("\(first)\(last)")
                    }

                    // Nickname-last initials
                    if eTokens.count >= 3,
                       let nick = eTokens[1].first,
                       let last = eTokens.last?.first {
                        candidateKeys.insert("\(nick)\(last)")
                    }
                }

                for key in candidateKeys {
                    initPostings[key, default: []].append(Int32(index))
                }
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
        self.sortedTokens = postings.keys.sorted()
        self.initialsPostings = initPostings
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
        if collector.hasCapacity(forClass: .acronym) && queryTokens.count == 1 && foldedQuery.count >= 2 && foldedQuery.count <= 4 {
            searchAcronyms(foldedQuery: foldedQuery, collector: &collector)
        }

        // Tier 3: Relationship / Token-Set permutation matching
        let isExplicitRel: Bool
        switch relQuery {
        case .explicitEntities:
            isExplicitRel = true
        case .tokenSet:
            isExplicitRel = false
        }

        if isExplicitRel || collector.hasCapacity(forClass: .relationshipPermuted) {
            searchRelationshipPermutations(relQuery: relQuery, queryTokens: queryTokens, collector: &collector)
        }

        // Tier 4: Fuzzy typo matching on token vocabulary
        if collector.hasCapacity(forClass: .fuzzyDistance1) && !queryTokens.isEmpty {
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

        var candidateSet: Set<Int32>?

        // Separate long tokens (>= 2 chars) from 1-char tokens
        let longTokens = queryTokens.filter { $0.count >= 2 }
        let singleCharTokens = queryTokens.filter { $0.count == 1 }

        if !longTokens.isEmpty {
            for token in longTokens {
                let posts = postings(forPrefix: token)
                if let existing = candidateSet {
                    candidateSet = existing.intersection(posts)
                } else {
                    candidateSet = Set(posts)
                }
            }
        } else if !singleCharTokens.isEmpty {
            // All tokens are 1-character initials (e.g. "h/r", "s/t")
            for token in singleCharTokens {
                let posts = initialsPostings[token] ?? []
                if let existing = candidateSet {
                    candidateSet = existing.intersection(posts)
                } else {
                    candidateSet = Set(posts)
                }
            }
        }

        // Check if query tokens also match entity initials (e.g. "sr/ts", "jb/sr")
        for token in queryTokens where token.count >= 2 && token.count <= 4 {
            if let initPosts = initialsPostings[token] {
                if let existing = candidateSet {
                    candidateSet = existing.union(initPosts)
                } else {
                    candidateSet = Set(initPosts)
                }
            }
        }

        let candidatesToCheck = candidateSet ?? Set()
        for candIdx32 in candidatesToCheck {
            let candIdx = Int(candIdx32)
            let original = originalStrings[candIdx]
            let (matches, maxDist, _) = relQuery.matches(candidateName: original, allowTypos: false)
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
            let (matches, maxDist, isPrefix) = relQuery.matches(candidateName: original, allowTypos: true)
            if matches && (maxDist > 0 || isPrefix) {
                let matchClass: SuggestionMatchClass
                if maxDist == 0 && isPrefix {
                    matchClass = .relationshipPermuted
                } else {
                    matchClass = (maxDist == 1) ? .fuzzyDistance1 : .fuzzyDistance2
                }
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

    /// Returns postings for all indexed tokens that begin with the given prefix.
    private func postings(forPrefix prefix: String) -> [Int32] {
        if let exact = tokenPostings[prefix] {
            return exact
        }
        guard prefix.count >= 2 else { return [] }

        // Binary search in sortedTokens for the first token >= prefix
        var low = 0
        var high = sortedTokens.count - 1
        var startIndex = sortedTokens.count

        while low <= high {
            let mid = (low + high) / 2
            if sortedTokens[mid] >= prefix {
                startIndex = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        var results: [Int32] = []
        var seen = Set<Int32>()
        var idx = startIndex
        var matchesCount = 0

        while idx < sortedTokens.count && sortedTokens[idx].hasPrefix(prefix) && matchesCount < 50 {
            if let post = tokenPostings[sortedTokens[idx]] {
                for id in post where !seen.contains(id) {
                    seen.insert(id)
                    results.append(id)
                }
            }
            idx += 1
            matchesCount += 1
        }
        return results
    }

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
