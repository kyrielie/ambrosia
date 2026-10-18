import XCTest
@testable import Ambrosia

final class IndexedHelperTests: XCTestCase {

    func testDuplicateKeysDoNotTrapAndFirstValueWins() {
        let map = LibraryQueryHelpers.indexed([(1, "a"), (2, "b"), (1, "c")])
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[1], "a")
        XCTAssertEqual(map[2], "b")
    }

    func testEmptyInputGivesEmptyMap() {
        let map: [Int: String] = LibraryQueryHelpers.indexed([])
        XCTAssertTrue(map.isEmpty)
    }

    func testDistinctKeysAreAllKept() {
        let map = LibraryQueryHelpers.indexed([("x", 1), ("y", 2), ("z", 3)])
        XCTAssertEqual(map, ["x": 1, "y": 2, "z": 3])
    }
}
