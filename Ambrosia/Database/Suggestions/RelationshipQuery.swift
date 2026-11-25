import Foundation

/// Parsed representation of a search query for entity-aware and relationship matching.
public enum RelationshipQuery: Sendable, Equatable {
    /// Explicit relationship mode where entities are separated by '/', '&', '+', '|', ',', or standalone 'x'.
    /// Each entity is a list of normalized tokens (e.g. [["steve", "rogers"], ["tony", "stark"]]).
    case explicitEntities([[String]])

    /// Token set mode (no explicit separators, only spaces).
    /// All query tokens must match distinct candidate tokens in any order.
    case tokenSet([String])

    /// Parses a raw user query into a `RelationshipQuery`.
    public static func parse(_ rawQuery: String) -> RelationshipQuery {
        let folded = SuggestionNormalizer.fold(rawQuery)

        // Check if query contains explicit separators
        var hasExplicitSeparator = false
        for char in folded where SuggestionNormalizer.isRelationshipSeparator(char) {
            hasExplicitSeparator = true
            break
        }

        // Also check for standalone 'x' surrounded by whitespace
        if !hasExplicitSeparator {
            let words = folded.components(separatedBy: .whitespaces)
            if words.contains("x") {
                hasExplicitSeparator = true
            }
        }

        if hasExplicitSeparator {
            // Split raw string by separators or standalone 'x'
            let entityStrings = splitEntities(folded)
            let entities = entityStrings.compactMap { entityStr -> [String]? in
                let tokens = SuggestionNormalizer.tokens(of: entityStr)
                return tokens.isEmpty ? nil : tokens
            }
            if entities.count > 1 {
                return .explicitEntities(entities)
            }
        }

        let tokens = SuggestionNormalizer.tokens(of: folded)
        return .tokenSet(tokens)
    }

    /// Splits folded text into separate entity strings using '/', '&', '+', '|', ',', or standalone ' x '.
    /// Canonicalizes reader tokens and cleans per-entity parenthetical qualifiers.
    public static func splitEntities(_ string: String) -> [String] {
        let normalized = SuggestionNormalizer.normalizeReaderTokens(string)

        // Check if primary relationship separators are present ('/' or '&' or standalone ' x ')
        let hasSlashOrAmp = normalized.contains("/") || normalized.contains("&")
        var hasStandaloneX = false
        for word in normalized.components(separatedBy: .whitespaces) where word == "x" {
            hasStandaloneX = true
            break
        }
        let hasPrimary = hasSlashOrAmp || hasStandaloneX

        var entities: [String] = []
        var current = ""

        let words = normalized.components(separatedBy: " ")
        var buffer: [String] = []

        for word in words {
            if word == "x" {
                if !buffer.isEmpty {
                    entities.append(buffer.joined(separator: " "))
                    buffer.removeAll()
                }
            } else {
                buffer.append(word)
            }
        }
        let normalizedForSeparators = buffer.joined(separator: " ")

        for char in normalizedForSeparators {
            let isSep: Bool
            if hasPrimary {
                // When primary separators exist, only '/' and '&' split entities
                isSep = (char == "/" || char == "&")
            } else {
                isSep = SuggestionNormalizer.isRelationshipSeparator(char)
            }

            if isSep {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { entities.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { entities.append(trimmed) }

        return entities.compactMap { entity in
            let cleaned = SuggestionNormalizer.stripParentheticals(entity)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Evaluates whether a candidate tag matches this query.
    /// Returns `(matches: Bool, maxTypoDistance: Int, isPrefix: Bool)` indicating whether all query parts
    /// were matched, the maximum edit distance, and whether any token matched as a proper prefix.
    public func matches(
        candidateName: String,
        allowTypos: Bool = true
    ) -> (matches: Bool, maxTypoDistance: Int, isPrefix: Bool) {
        let (baseName, _) = SuggestionNormalizer.stripTrailingQualifier(candidateName)
        let candidateFolded = SuggestionNormalizer.fold(baseName)

        switch self {
        case .explicitEntities(let queryEntities):
            guard !queryEntities.isEmpty else { return (false, 0, false) }
            let candidateEntitiesRaw = Self.splitEntities(candidateFolded)
            let candidateEntities = candidateEntitiesRaw.compactMap { raw -> [String]? in
                let tokens = SuggestionNormalizer.tokens(of: raw)
                return tokens.isEmpty ? nil : tokens
            }

            // Must have at least as many candidate entities as query entities
            guard candidateEntities.count >= queryEntities.count else { return (false, 0, false) }

            // Up to 5 entities: check all injective permutations
            return matchInjectiveEntities(
                queryEntities: queryEntities,
                candidateEntities: candidateEntities,
                allowTypos: allowTypos
            )

        case .tokenSet(let queryTokens):
            guard !queryTokens.isEmpty else { return (false, 0, false) }
            let candidateTokens = SuggestionNormalizer.tokens(of: candidateFolded)
            guard candidateTokens.count >= queryTokens.count else { return (false, 0, false) }

            return matchInjectiveTokens(
                queryTokens: queryTokens,
                candidateTokens: candidateTokens,
                allowTypos: allowTypos
            )
        }
    }

    private func matchInjectiveEntities(
        queryEntities: [[String]],
        candidateEntities: [[String]],
        allowTypos: Bool
    ) -> (matches: Bool, maxTypoDistance: Int, isPrefix: Bool) {
        var usedCandidateIndices = Set<Int>()
        var overallMaxDistance = 0
        var anyPrefix = false

        for qEntity in queryEntities {
            var matchedIndex: Int?
            var bestDistance = Int.max
            var bestIsPrefix = false

            for (cIdx, cEntity) in candidateEntities.enumerated() where !usedCandidateIndices.contains(cIdx) {
                let (matches, dist, isPrefix) = matchTokensInEntity(
                    queryTokens: qEntity,
                    candidateTokens: cEntity,
                    allowTypos: allowTypos
                )
                if matches && dist < bestDistance {
                    bestDistance = dist
                    bestIsPrefix = isPrefix
                    matchedIndex = cIdx
                    if dist == 0 && !isPrefix { break }
                }
            }

            guard let foundIdx = matchedIndex else {
                return (false, 0, false)
            }
            usedCandidateIndices.insert(foundIdx)
            overallMaxDistance = max(overallMaxDistance, bestDistance)
            if bestIsPrefix { anyPrefix = true }
        }

        return (true, overallMaxDistance, anyPrefix)
    }

    private func matchTokensInEntity(
        queryTokens: [String],
        candidateTokens: [String],
        allowTypos: Bool
    ) -> (matches: Bool, maxTypoDistance: Int, isPrefix: Bool) {
        // Initials check if query entity is a single token between 2 and 4 characters
        if queryTokens.count == 1 {
            let queryToken = queryTokens[0]
            if queryToken.count >= 2 && queryToken.count <= 4 {
                let allInitials = candidateTokens.compactMap { $0.first.map(String.init) }.joined()
                if allInitials == queryToken {
                    return (true, 0, false)
                }
                if candidateTokens.count >= 2,
                   let first = candidateTokens.first?.first,
                   let last = candidateTokens.last?.first {
                    let flInitials = "\(first)\(last)"
                    if flInitials == queryToken {
                        return (true, 0, false)
                    }
                }
                if candidateTokens.count >= 3,
                   let nick = candidateTokens[1].first,
                   let last = candidateTokens.last?.first {
                    let nlInitials = "\(nick)\(last)"
                    if nlInitials == queryToken {
                        return (true, 0, false)
                    }
                }
            }
        }

        guard candidateTokens.count >= queryTokens.count else { return (false, 0, false) }
        return matchInjectiveTokens(
            queryTokens: queryTokens,
            candidateTokens: candidateTokens,
            allowTypos: allowTypos
        )
    }

    private func matchInjectiveTokens(
        queryTokens: [String],
        candidateTokens: [String],
        allowTypos: Bool
    ) -> (matches: Bool, maxTypoDistance: Int, isPrefix: Bool) {
        var usedCandidates = Set<Int>()
        var overallMaxDistance = 0
        var anyPrefix = false

        for qToken in queryTokens {
            var matchedIndex: Int?
            var bestDistance = Int.max
            var bestIsPrefix = false
            let maxAllowed = allowTypos ? TypoDistance.maxDistance(forQueryLength: qToken.count) : 0

            for (cIdx, cToken) in candidateTokens.enumerated() where !usedCandidates.contains(cIdx) {
                if cToken.hasPrefix(qToken) {
                    matchedIndex = cIdx
                    bestDistance = 0
                    bestIsPrefix = (cToken != qToken)
                    break
                }
                if maxAllowed > 0 {
                    let dist = TypoDistance.prefixDistance(query: qToken, candidate: cToken, maxDistance: maxAllowed)
                    if dist <= maxAllowed && dist < bestDistance {
                        bestDistance = dist
                        bestIsPrefix = false
                        matchedIndex = cIdx
                    }
                }
            }

            guard let foundIdx = matchedIndex else {
                return (false, 0, false)
            }
            usedCandidates.insert(foundIdx)
            overallMaxDistance = max(overallMaxDistance, bestDistance)
            if bestIsPrefix { anyPrefix = true }
        }

        return (true, overallMaxDistance, anyPrefix)
    }
}
