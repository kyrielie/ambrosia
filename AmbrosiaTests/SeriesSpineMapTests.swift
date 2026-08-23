import XCTest
@testable import Ambrosia

/// Coverage for `SeriesSpineMap` (`Ambrosia/Reader/SeriesSpineMap.swift`) --
/// pure arithmetic over `workIDs`/`spineCounts`, constructed directly with no
/// fixture needed.
final class SeriesSpineMapTests: XCTestCase {

    private func makeMap() -> SeriesSpineMap {
        // 3 works: work 0 has 2 spine items, work 1 has 5, work 2 has 1. count == 8.
        SeriesSpineMap(workIDs: [100, 200, 300], spineCounts: [2, 5, 1])
    }

    // MARK: - ref(atGlobalIndex:)

    func testRefInRangeResolvesToCorrectWorkAndLocalIndex() {
        let map = makeMap()
        XCTAssertEqual(map.ref(atGlobalIndex: 0)?.workIndex, 0)
        XCTAssertEqual(map.ref(atGlobalIndex: 0)?.localIndex, 0)
        XCTAssertEqual(map.ref(atGlobalIndex: 1)?.workIndex, 0)
        XCTAssertEqual(map.ref(atGlobalIndex: 1)?.localIndex, 1)
        XCTAssertEqual(map.ref(atGlobalIndex: 2)?.workIndex, 1)
        XCTAssertEqual(map.ref(atGlobalIndex: 2)?.localIndex, 0)
        XCTAssertEqual(map.ref(atGlobalIndex: 6)?.workIndex, 1)
        XCTAssertEqual(map.ref(atGlobalIndex: 6)?.localIndex, 4)
        XCTAssertEqual(map.ref(atGlobalIndex: 7)?.workIndex, 2)
        XCTAssertEqual(map.ref(atGlobalIndex: 7)?.localIndex, 0)
    }

    func testRefOutOfRangeReturnsNil() {
        let map = makeMap()
        XCTAssertNil(map.ref(atGlobalIndex: -1))
        XCTAssertNil(map.ref(atGlobalIndex: 8)) // count == 8, valid range is 0...7
        XCTAssertNil(map.ref(atGlobalIndex: 100))
    }

    // MARK: - workID(atGlobalIndex:)

    func testWorkIDReturnsCorrectID() {
        let map = makeMap()
        XCTAssertEqual(map.workID(atGlobalIndex: 0), 100)
        XCTAssertEqual(map.workID(atGlobalIndex: 1), 100)
        XCTAssertEqual(map.workID(atGlobalIndex: 2), 200)
        XCTAssertEqual(map.workID(atGlobalIndex: 7), 300)
    }

    func testWorkIDReturnsNilWhenRefIsNil() {
        let map = makeMap()
        XCTAssertNil(map.workID(atGlobalIndex: -1))
        XCTAssertNil(map.workID(atGlobalIndex: 8))
    }

    /// Defensive double-guard (lines 51-53): `workIDs.indices.contains(ref.workIndex)`
    /// guards against `workIDs.count != spineCounts.count`, a state that shouldn't
    /// normally occur but is defended against anyway.
    func testWorkIDReturnsNilWhenWorkIDsDoesNotCoverResolvedWorkIndex() {
        // 3 spineCounts entries (count == 8, work indices 0,1,2 resolvable) but
        // only 2 workIDs -- ref(atGlobalIndex:) can resolve workIndex 2, but
        // workIDs.indices does not contain 2.
        let map = SeriesSpineMap(workIDs: [100, 200], spineCounts: [2, 5, 1])
        XCTAssertNotNil(map.ref(atGlobalIndex: 7))
        XCTAssertEqual(map.ref(atGlobalIndex: 7)?.workIndex, 2)
        XCTAssertNil(map.workID(atGlobalIndex: 7))
    }

    // MARK: - globalIndex(workIndex:localIndex:)

    func testGlobalIndexRoundTripsWithRefForEveryValidPair() throws {
        let map = makeMap()
        let spineCounts = [2, 5, 1]
        for workIndex in 0..<3 {
            for localIndex in 0..<spineCounts[workIndex] {
                let global = map.globalIndex(workIndex: workIndex, localIndex: localIndex)
                XCTAssertNotNil(global, "workIndex \(workIndex) localIndex \(localIndex)")
                let unwrappedGlobal = try XCTUnwrap(global)
                let ref = map.ref(atGlobalIndex: unwrappedGlobal)
                XCTAssertEqual(ref?.workIndex, workIndex)
                XCTAssertEqual(ref?.localIndex, localIndex)
            }
        }
    }

    func testGlobalIndexNilForOutOfRangeLocalIndex() {
        let map = makeMap()
        XCTAssertNil(map.globalIndex(workIndex: 0, localIndex: -1))
        XCTAssertNil(map.globalIndex(workIndex: 0, localIndex: 2)) // work 0 has spineCount 2, valid 0...1
        XCTAssertNil(map.globalIndex(workIndex: 2, localIndex: 1)) // work 2 has spineCount 1, valid 0...0
    }

    func testGlobalIndexNilForOutOfRangeWorkIndex() {
        let map = makeMap()
        XCTAssertNil(map.globalIndex(workIndex: -1, localIndex: 0))
        XCTAssertNil(map.globalIndex(workIndex: 3, localIndex: 0))
    }

    // MARK: - isLastItemInWork / isFirstItemInWork

    func testBoundaryValuesAcrossWorkTransitions() {
        let map = makeMap()
        // First item of work 0.
        XCTAssertTrue(map.isFirstItemInWork(0))
        XCTAssertFalse(map.isLastItemInWork(0))
        // Last item of work 0 (global index 1).
        XCTAssertTrue(map.isLastItemInWork(1))
        XCTAssertFalse(map.isFirstItemInWork(1))
        // First item of work 1 (global index 2), immediately after work 0's last.
        XCTAssertTrue(map.isFirstItemInWork(2))
        XCTAssertFalse(map.isLastItemInWork(2))
        // Last item of the last work (global index 7).
        XCTAssertTrue(map.isLastItemInWork(7))
        XCTAssertTrue(map.isFirstItemInWork(7)) // work 2 has only 1 item: both first and last.
    }

    func testIsLastAndIsFirstReturnFalseOutOfRange() {
        let map = makeMap()
        XCTAssertFalse(map.isLastItemInWork(-1))
        XCTAssertFalse(map.isLastItemInWork(8))
        XCTAssertFalse(map.isFirstItemInWork(-1))
        XCTAssertFalse(map.isFirstItemInWork(8))
    }

    // MARK: - spineCount(forWorkIndex:)

    func testSpineCountValidAndOutOfRangeIndex() {
        let map = makeMap()
        XCTAssertEqual(map.spineCount(forWorkIndex: 0), 2)
        XCTAssertEqual(map.spineCount(forWorkIndex: 1), 5)
        XCTAssertEqual(map.spineCount(forWorkIndex: 2), 1)
        XCTAssertNil(map.spineCount(forWorkIndex: -1))
        XCTAssertNil(map.spineCount(forWorkIndex: 3))
    }

    // MARK: - Property-based-flavored walk

    func testWalkingEveryGlobalIndexNeverReturnsNilAndMatchesExpectedWork() {
        let map = makeMap()
        XCTAssertEqual(map.count, 8)
        let expectedWorkIDPerIndex = [100, 100, 200, 200, 200, 200, 200, 300]
        for global in 0..<map.count {
            XCTAssertNotNil(map.ref(atGlobalIndex: global), "global index \(global)")
            XCTAssertEqual(map.workID(atGlobalIndex: global), expectedWorkIDPerIndex[global], "global index \(global)")
        }
    }
}
