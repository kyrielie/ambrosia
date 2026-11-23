// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct RelevanceRanking: Equatable, Sendable {
    var ids: [Int]
    var isOrdered: Bool
}

enum RelevancePlan: Equatable, Sendable {
    case empty
    case ftsOnly(ids: [Int])
    case semanticOnly(ranking: RelevanceRanking, hits: [(id: Int, score: Double)])
    case fused(ranking: RelevanceRanking, fused: [HybridSearchResult], hits: [(id: Int, score: Double)], ftsIDs: Set<Int>)
    case needsLexicalFallback(hits: [(id: Int, score: Double)])

    static func == (lhs: RelevancePlan, rhs: RelevancePlan) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty):
            return true
        case (.ftsOnly(let lIDs), .ftsOnly(let rIDs)):
            return lIDs == rIDs
        case (.semanticOnly(let lRank, let lHits), .semanticOnly(let rRank, let rHits)):
            return lRank == rRank && zipHitsEqual(lHits, rHits)
        case (.fused(let lRank, let lFused, let lHits, let lFTS), .fused(let rRank, let rFused, let rHits, let rFTS)):
            return lRank == rRank && lFused == rFused && zipHitsEqual(lHits, rHits) && lFTS == rFTS
        case (.needsLexicalFallback(let lHits), .needsLexicalFallback(let rHits)):
            return zipHitsEqual(lHits, rHits)
        default:
            return false
        }
    }

    private static func zipHitsEqual(
        _ lhsHits: [(id: Int, score: Double)],
        _ rhsHits: [(id: Int, score: Double)]
    ) -> Bool {
        guard lhsHits.count == rhsHits.count else { return false }
        for (leftHit, rightHit) in zip(lhsHits, rhsHits) {
            if leftHit.id != rightHit.id || leftHit.score != rightHit.score { return false }
        }
        return true
    }
}

enum RelevanceRankingPlanner {
    /// Plans the relevance ranking strategy and badge payload from search inputs.
    static func plan(
        ftsIDs: [Int],
        semanticHits: [(id: Int, score: Double)],
        hasPlainTerms: Bool
    ) -> RelevancePlan {
        if !ftsIDs.isEmpty && !semanticHits.isEmpty {
            let fused = HybridSearchCoordinator.fuse(lexicalIDs: ftsIDs, semanticHits: semanticHits, lexicalIsRanked: false)
            let ranking = RelevanceRanking(ids: fused.map(\.bookID), isOrdered: true)
            return .fused(ranking: ranking, fused: fused, hits: semanticHits, ftsIDs: Set(ftsIDs))
        } else if !semanticHits.isEmpty {
            if hasPlainTerms {
                return .needsLexicalFallback(hits: semanticHits)
            }
            let ranking = RelevanceRanking(ids: semanticHits.map(\.id), isOrdered: true)
            return .semanticOnly(ranking: ranking, hits: semanticHits)
        } else if !ftsIDs.isEmpty {
            return .ftsOnly(ids: ftsIDs)
        }
        return .empty
    }

    /// Fuses lazily fetched lexical fallback IDs with semantic hits when plain terms are present.
    static func fuseLexicalFallback(
        lexicalIDs: [Int],
        semanticHits: [(id: Int, score: Double)]
    ) -> (ranking: RelevanceRanking, fused: [HybridSearchResult]?) {
        if !lexicalIDs.isEmpty {
            let fused = HybridSearchCoordinator.fuse(lexicalIDs: lexicalIDs, semanticHits: semanticHits, lexicalIsRanked: false)
            return (RelevanceRanking(ids: fused.map(\.bookID), isOrdered: true), fused)
        }
        return (RelevanceRanking(ids: semanticHits.map(\.id), isOrdered: true), nil)
    }
}
