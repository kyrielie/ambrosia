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
}
