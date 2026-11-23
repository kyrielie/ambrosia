// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class RelevanceRankingPlannerTests: XCTestCase {

    // MARK: - Branch Table Tests

    func testPlan_emptyInputs_returnsEmpty() {
        let plan = RelevanceRankingPlanner.plan(
            ftsIDs: [],
            semanticHits: [],
            hasPlainTerms: false
        )
        XCTAssertEqual(plan, .empty)
    }

    func testPlan_ftsOnly_returnsFtsOnlyWithUnorderedFlag() {
        let ftsIDs = [101, 102, 103]
        let plan = RelevanceRankingPlanner.plan(
            ftsIDs: ftsIDs,
            semanticHits: [],
            hasPlainTerms: false
        )
        XCTAssertEqual(plan, .ftsOnly(ids: ftsIDs))
    }

    func testPlan_semanticOnly_withoutPlainTerms_returnsSemanticOnly() {
        let semanticHits: [(id: Int, score: Double)] = [(10, 0.95), (20, 0.82)]
        let plan = RelevanceRankingPlanner.plan(
            ftsIDs: [],
            semanticHits: semanticHits,
            hasPlainTerms: false
        )
        let expectedRanking = RelevanceRanking(ids: [10, 20], isOrdered: true)
        XCTAssertEqual(plan, .semanticOnly(ranking: expectedRanking, hits: semanticHits))
    }

    func testPlan_semanticWithPlainTerms_signalsNeedsLexicalFallback() {
        let semanticHits: [(id: Int, score: Double)] = [(10, 0.95), (20, 0.82)]
        let plan = RelevanceRankingPlanner.plan(
            ftsIDs: [],
            semanticHits: semanticHits,
            hasPlainTerms: true
        )
        XCTAssertEqual(plan, .needsLexicalFallback(hits: semanticHits))
    }

    func testPlan_bothFTSAndSemantic_fusesWithUnrankedLexical() {
        let ftsIDs = [10, 30]
        let semanticHits: [(id: Int, score: Double)] = [(10, 0.95), (20, 0.82)]
        let plan = RelevanceRankingPlanner.plan(
            ftsIDs: ftsIDs,
            semanticHits: semanticHits,
            hasPlainTerms: false
        )

        guard case .fused(let ranking, let fused, let hits, let ftsSet) = plan else {
            XCTFail("Expected .fused plan, got \(plan)")
            return
        }

        XCTAssertTrue(ranking.isOrdered)
        XCTAssertEqual(ftsSet, Set([10, 30]))
        XCTAssertEqual(hits.count, 2)
        // Book 10 is in both, so it ranks first
        XCTAssertEqual(ranking.ids.first, 10)
        XCTAssertEqual(fused.map(\.bookID), ranking.ids)
    }

    // MARK: - Lexical Fallback Fusion

    func testFuseLexicalFallback_withNonEmptyLexical_fusesResults() {
        let lexicalIDs = [20, 30]
        let semanticHits: [(id: Int, score: Double)] = [(10, 0.95), (20, 0.82)]

        let (ranking, fused) = RelevanceRankingPlanner.fuseLexicalFallback(
            lexicalIDs: lexicalIDs,
            semanticHits: semanticHits
        )

        XCTAssertTrue(ranking.isOrdered)
        XCTAssertNotNil(fused)
        // Book 20 is present in both lexical and semantic, so it gets higher RRF score
        XCTAssertEqual(ranking.ids.first, 20)
    }

    func testFuseLexicalFallback_withEmptyLexical_fallsBackToSemanticIDs() {
        let semanticHits: [(id: Int, score: Double)] = [(10, 0.95), (20, 0.82)]

        let (ranking, fused) = RelevanceRankingPlanner.fuseLexicalFallback(
            lexicalIDs: [],
            semanticHits: semanticHits
        )

        XCTAssertTrue(ranking.isOrdered)
        XCTAssertNil(fused)
        XCTAssertEqual(ranking.ids, [10, 20])
    }

    // MARK: - Expansion Merge Precedence

    func testCurrentMergePrefersFilterExpansions() {
        let filterExpansions: [String: [String]] = [
            "angst": ["hurt/comfort", "emotional hurt"],
            "fluff": ["domestic fluff"]
        ]
        let searchExpansions: [String: [String]] = [
            "angst": ["general angst"],
            "au": ["modern au"]
        ]

        let merged = TagRelevanceTargets.mergedExpansions(
            filter: filterExpansions,
            search: searchExpansions
        )

        // "angst" collides; filter expansion wins
        XCTAssertEqual(merged["angst"], ["hurt/comfort", "emotional hurt"])
        // non-colliding keys preserved
        XCTAssertEqual(merged["fluff"], ["domestic fluff"])
        XCTAssertEqual(merged["au"], ["modern au"])
    }
}
