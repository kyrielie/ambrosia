// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class HybridSearchCoordinatorTests: XCTestCase {

    func testUnrankedLexicalContributesEqualScore() {
        let lexicalIDs = [10, 20, 30]
        let semanticHits: [(id: Int, score: Double)] = []

        let results = HybridSearchCoordinator.fuse(
            lexicalIDs: lexicalIDs,
            semanticHits: semanticHits,
            kConstant: 60.0,
            lexicalIsRanked: false
        )

        XCTAssertEqual(results.count, 3)
        // With lexicalIsRanked == false, every hit gets 1 / (60 + 1)
        let expectedScore = 1.0 / 61.0
        for item in results {
            XCTAssertEqual(item.rrfScore, expectedScore, accuracy: 0.000001)
        }
    }

    func testRankedLexicalUnchanged() {
        let lexicalIDs = [10, 20]
        let semanticHits: [(id: Int, score: Double)] = []

        let results = HybridSearchCoordinator.fuse(
            lexicalIDs: lexicalIDs,
            semanticHits: semanticHits,
            kConstant: 60.0,
            lexicalIsRanked: true
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].bookID, 10)
        XCTAssertEqual(results[0].rrfScore, 1.0 / 61.0, accuracy: 0.000001)
        XCTAssertEqual(results[1].bookID, 20)
        XCTAssertEqual(results[1].rrfScore, 1.0 / 62.0, accuracy: 0.000001)
    }

    // MARK: - Pass T2 Characterization & Boundary Tests

    func testFuse_emptyInputs_returnsEmpty() {
        let results = HybridSearchCoordinator.fuse(
            lexicalIDs: [],
            semanticHits: []
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testFuse_semanticOnly_preservesSemanticRanking() {
        let semanticHits: [(id: Int, score: Double)] = [
            (101, 0.98),
            (102, 0.85),
            (103, 0.72)
        ]

        let results = HybridSearchCoordinator.fuse(
            lexicalIDs: [],
            semanticHits: semanticHits,
            kConstant: 60.0
        )

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.bookID), [101, 102, 103])
        XCTAssertEqual(results[0].rrfScore, 1.0 / 61.0, accuracy: 0.000001)
        XCTAssertEqual(results[1].rrfScore, 1.0 / 62.0, accuracy: 0.000001)
        XCTAssertEqual(results[2].rrfScore, 1.0 / 63.0, accuracy: 0.000001)
        XCTAssertNil(results[0].lexicalRank)
        XCTAssertEqual(results[0].semanticRank, 1)
        XCTAssertEqual(results[0].semanticScore, 0.98)
    }

    func testFuse_overlappingIDs_aggregatesRRFScores() {
        let lexicalIDs = [1, 2]
        let semanticHits: [(id: Int, score: Double)] = [(2, 0.9), (3, 0.8)]

        let results = HybridSearchCoordinator.fuse(
            lexicalIDs: lexicalIDs,
            semanticHits: semanticHits,
            kConstant: 60.0,
            lexicalIsRanked: true
        )

        XCTAssertEqual(results.count, 3)
        // Book 2 is rank 2 in lexical (1/62) and rank 1 in semantic (1/61)
        let expectedScore2 = (1.0 / 62.0) + (1.0 / 61.0)
        XCTAssertEqual(results[0].bookID, 2)
        XCTAssertEqual(results[0].rrfScore, expectedScore2, accuracy: 0.000001)
        XCTAssertEqual(results[0].lexicalRank, 2)
        XCTAssertEqual(results[0].semanticRank, 1)
    }

    func testFuse_kConstantVariation() {
        let lexicalIDs = [1]
        let semanticHits: [(id: Int, score: Double)] = [(1, 0.9)]

        let resultsK10 = HybridSearchCoordinator.fuse(
            lexicalIDs: lexicalIDs,
            semanticHits: semanticHits,
            kConstant: 10.0,
            lexicalIsRanked: true
        )
        // (1 / (10 + 1)) + (1 / (10 + 1)) = 2 / 11
        XCTAssertEqual(resultsK10[0].rrfScore, 2.0 / 11.0, accuracy: 0.000001)

        let resultsK100 = HybridSearchCoordinator.fuse(
            lexicalIDs: lexicalIDs,
            semanticHits: semanticHits,
            kConstant: 100.0,
            lexicalIsRanked: true
        )
        // (1 / (100 + 1)) + (1 / (100 + 1)) = 2 / 101
        XCTAssertEqual(resultsK100[0].rrfScore, 2.0 / 101.0, accuracy: 0.000001)
    }

    func testFuse_deterministicTieOrder() {
        // Equal scores break ties deterministically by bookID ascending
        let lexicalIDs = [20, 10, 30]
        let results = HybridSearchCoordinator.fuse(
            lexicalIDs: lexicalIDs,
            semanticHits: [],
            kConstant: 60.0,
            lexicalIsRanked: false
        )

        XCTAssertEqual(results.count, 3)
        // All have same score; should sort by bookID ascending (10, 20, 30)
        XCTAssertEqual(results.map(\.bookID), [10, 20, 30])
    }

    func testFuse_unrankedLexicalWithManyHits_givesIdenticalScores() {
        let lexicalIDs = Array(1...50)
        let results = HybridSearchCoordinator.fuse(
            lexicalIDs: lexicalIDs,
            semanticHits: [],
            kConstant: 60.0,
            lexicalIsRanked: false
        )

        XCTAssertEqual(results.count, 50)
        let singleHitScore = 1.0 / 61.0
        for item in results {
            XCTAssertEqual(item.rrfScore, singleHitScore, accuracy: 0.000001)
        }
    }
}
