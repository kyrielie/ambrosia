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
    public static func splitEntities(_ string: String) -> [String] {
        var entities: [String] = []
        var current = ""

        let words = string.components(separatedBy: " ")
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
            if SuggestionNormalizer.isRelationshipSeparator(char) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { entities.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { entities.append(trimmed) }

        return entities
    }

    /// Evaluates whether a candidate tag matches this query.
    /// Returns `(matches: Bool, maxTypoDistance: Int)` indicating whether all query parts
    /// were matched and the maximum edit distance across all matched tokens.
    public func matches(
        candidateName: String,
        allowTypos: Bool = true
    ) -> (matches: Bool, maxTypoDistance: Int) {
        let (baseName, _) = SuggestionNormalizer.stripTrailingQualifier(candidateName)
        let candidateFolded = SuggestionNormalizer.fold(baseName)

        switch self {
        case .explicitEntities(let queryEntities):
            guard !queryEntities.isEmpty else { return (false, 0) }
            let candidateEntitiesRaw = Self.splitEntities(candidateFolded)
            let candidateEntities = candidateEntitiesRaw.compactMap { raw -> [String]? in
                let tokens = SuggestionNormalizer.tokens(of: raw)
                return tokens.isEmpty ? nil : tokens
            }

            // Must have at least as many candidate entities as query entities
            guard candidateEntities.count >= queryEntities.count else { return (false, 0) }

            // Up to 5 entities: check all injective permutations
            return matchInjectiveEntities(
                queryEntities: queryEntities,
                candidateEntities: candidateEntities,
                allowTypos: allowTypos
            )

        case .tokenSet(let queryTokens):
            guard !queryTokens.isEmpty else { return (false, 0) }
            let candidateTokens = SuggestionNormalizer.tokens(of: candidateFolded)
            guard candidateTokens.count >= queryTokens.count else { return (false, 0) }

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
    ) -> (matches: Bool, maxTypoDistance: Int) {
        var usedCandidateIndices = Set<Int>()
        var overallMaxDistance = 0

        for qEntity in queryEntities {
            var matchedIndex: Int?
            var bestDistance = Int.max

            for (cIdx, cEntity) in candidateEntities.enumerated() where !usedCandidateIndices.contains(cIdx) {
                let (matches, dist) = matchTokensInEntity(
                    queryTokens: qEntity,
                    candidateTokens: cEntity,
                    allowTypos: allowTypos
                )
                if matches && dist < bestDistance {
                    bestDistance = dist
                    matchedIndex = cIdx
                    if dist == 0 { break }
                }
            }

            guard let foundIdx = matchedIndex else {
                return (false, 0)
            }
            usedCandidateIndices.insert(foundIdx)
            overallMaxDistance = max(overallMaxDistance, bestDistance)
        }

        return (true, overallMaxDistance)
    }

    private func matchTokensInEntity(
        queryTokens: [String],
        candidateTokens: [String],
        allowTypos: Bool
    ) -> (matches: Bool, maxTypoDistance: Int) {
        guard candidateTokens.count >= queryTokens.count else { return (false, 0) }
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
    ) -> (matches: Bool, maxTypoDistance: Int) {
        var usedCandidates = Set<Int>()
        var overallMaxDistance = 0

        for qToken in queryTokens {
            var matchedIndex: Int?
            var bestDistance = Int.max
            let maxAllowed = allowTypos ? TypoDistance.maxDistance(forQueryLength: qToken.count) : 0

            for (cIdx, cToken) in candidateTokens.enumerated() where !usedCandidates.contains(cIdx) {
                if cToken.hasPrefix(qToken) {
                    matchedIndex = cIdx
                    bestDistance = 0
                    break
                }
                if maxAllowed > 0 {
                    let dist = TypoDistance.prefixDistance(query: qToken, candidate: cToken, maxDistance: maxAllowed)
                    if dist <= maxAllowed && dist < bestDistance {
                        bestDistance = dist
                        matchedIndex = cIdx
                    }
                }
            }

            guard let foundIdx = matchedIndex else {
                return (false, 0)
            }
            usedCandidates.insert(foundIdx)
            overallMaxDistance = max(overallMaxDistance, bestDistance)
        }

        return (true, overallMaxDistance)
    }
}
