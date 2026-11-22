// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct HybridSearchResult: Identifiable, Equatable, Sendable {
    public let bookID: Int
    public let rrfScore: Double
    public let lexicalRank: Int?
    public let semanticRank: Int?
    public let semanticScore: Double?
    public var id: Int { bookID }

    public init(bookID: Int, rrfScore: Double, lexicalRank: Int? = nil, semanticRank: Int? = nil, semanticScore: Double? = nil) {
        self.bookID = bookID
        self.rrfScore = rrfScore
        self.lexicalRank = lexicalRank
        self.semanticRank = semanticRank
        self.semanticScore = semanticScore
    }
}

public enum HybridSearchCoordinator {
    public static let defaultK: Double = 60.0

    /// Fuses an ordered list of lexical book IDs with scored semantic hits using Reciprocal Rank Fusion.
    public static func fuse(
        lexicalIDs: [Int],
        semanticHits: [(id: Int, score: Double)],
        kConstant: Double = defaultK,
        lexicalIsRanked: Bool = true
    ) -> [HybridSearchResult] {
        var scores: [Int: Double] = [:]
        var lexicalRanks: [Int: Int] = [:]
        var semanticRanks: [Int: Int] = [:]
        var semanticScores: [Int: Double] = [:]

        for (rankIndex, bookID) in lexicalIDs.enumerated() {
            let rank = rankIndex + 1
            lexicalRanks[bookID] = rank
            if lexicalIsRanked {
                scores[bookID, default: 0.0] += 1.0 / (kConstant + Double(rank))
            } else {
                scores[bookID, default: 0.0] += 1.0 / (kConstant + 1.0)
            }
        }

        for (rankIndex, hit) in semanticHits.enumerated() {
            let rank = rankIndex + 1
            semanticRanks[hit.id] = rank
            semanticScores[hit.id] = hit.score
            scores[hit.id, default: 0.0] += 1.0 / (kConstant + Double(rank))
        }

        var results: [HybridSearchResult] = []
        results.reserveCapacity(scores.count)

        for (bookID, rrfScore) in scores {
            results.append(
                HybridSearchResult(
                    bookID: bookID,
                    rrfScore: rrfScore,
                    lexicalRank: lexicalRanks[bookID],
                    semanticRank: semanticRanks[bookID],
                    semanticScore: semanticScores[bookID]
                )
            )
        }

        results.sort { lhs, rhs in
            if lhs.rrfScore != rhs.rrfScore {
                return lhs.rrfScore > rhs.rrfScore
            }
            return lhs.bookID < rhs.bookID
        }

        return results
    }
}
