import XCTest
@testable import Ambrosia

final class RelevanceOrderingTests: XCTestCase {

    func testRelevanceOrderingNoRankedListSortsByPosition() {
        let posMap: [Int: TagPosition] = [
            1: TagPosition(roleRank: 0, index: 0), // First-listed relationship
            2: TagPosition(roleRank: 0, index: 1), // Later relationship
            3: TagPosition(roleRank: 1, index: 0), // First-listed character
            4: TagPosition(roleRank: 3, index: 5)  // Background freeform
        ]

        let ids = [4, 3, 2, 1]
        let sorted = ids.sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: false
            )
        }

        XCTAssertEqual(sorted, [1, 2, 3, 4])
    }

    func testRelevanceOrderingRankedListUsesPositionAsTieBreak() {
        // Book 1: candidate rank 0 (strong text match), but later relationship
        // Book 2: candidate rank 1 (weaker text match), but first-listed relationship
        // Book 3: candidate rank 1 (weaker text match), later relationship
        let rankMap: [Int: Int] = [
            1: 0,
            2: 1,
            3: 1
        ]
        let posMap: [Int: TagPosition] = [
            1: TagPosition(roleRank: 0, index: 1),
            2: TagPosition(roleRank: 0, index: 0),
            3: TagPosition(roleRank: 0, index: 1)
        ]

        let ids = [3, 2, 1]
        let sorted = ids.sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: rankMap,
                posMap: posMap,
                ascending: false
            )
        }

        // Rank 0 strictly beats Rank 1; between Books 2 and 3 (both Rank 1), Book 2 wins tie-break.
        XCTAssertEqual(sorted, [1, 2, 3])
    }

    func testUnmatchedBooksSortLast() {
        let posMap: [Int: TagPosition] = [
            10: TagPosition(roleRank: 0, index: 0)
        ]

        let ids = [20, 10] // 20 has no position in posMap
        let sorted = ids.sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: false
            )
        }

        XCTAssertEqual(sorted, [10, 20])
    }

    func testDirectionFlip() {
        let posMap: [Int: TagPosition] = [
            1: TagPosition(roleRank: 0, index: 0),
            2: TagPosition(roleRank: 0, index: 1)
        ]

        let descending = [1, 2].sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: false
            )
        }
        XCTAssertEqual(descending, [1, 2])

        let ascending = [1, 2].sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: true
            )
        }
        XCTAssertEqual(ascending, [2, 1])
    }

    func testCustomTieBreakUsedAfterPosition() {
        let posMap: [Int: TagPosition] = [
            10: TagPosition(roleRank: 0, index: 0),
            20: TagPosition(roleRank: 0, index: 0)
        ]

        // Custom tie break: prefer 20 over 10 (reverse of book ID)
        let sorted = [10, 20].sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: false,
                tieBreak: { id1, id2 in id1 > id2 }
            )
        }
        XCTAssertEqual(sorted, [20, 10])
    }

    func testDefaultTieBreakIsBookID() {
        let posMap: [Int: TagPosition] = [
            10: TagPosition(roleRank: 0, index: 0),
            20: TagPosition(roleRank: 0, index: 0)
        ]

        let sorted = [20, 10].sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: false
            )
        }
        XCTAssertEqual(sorted, [10, 20])
    }
}
