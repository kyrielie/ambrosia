import XCTest
@testable import Ambrosia

final class TypoDistanceTests: XCTestCase {

    func testExactDistanceZero() {
        XCTAssertEqual(TypoDistance.distance("angst", "angst"), 0)
        XCTAssertEqual(TypoDistance.distance("", ""), 0)
    }

    func testSingleEditDistanceOne() {
        // Transposition
        XCTAssertEqual(TypoDistance.distance("angts", "angst"), 1)
        // Deletion
        XCTAssertEqual(TypoDistance.distance("angt", "angst"), 1)
        // Insertion
        XCTAssertEqual(TypoDistance.distance("astlat", "astolat"), 1)
        // Substitution
        XCTAssertEqual(TypoDistance.distance("gaimen", "gaiman"), 1)
    }

    func testDistanceBoundedByMaxDistance() {
        // Distance is 2, should return 2 when maxDistance is 2
        XCTAssertEqual(TypoDistance.distance("fluf", "fluff", maxDistance: 2), 1)
        XCTAssertEqual(TypoDistance.distance("flf", "fluff", maxDistance: 2), 2)

        // Distance > 2 should return maxDistance + 1
        XCTAssertEqual(TypoDistance.distance("xyz", "fluff", maxDistance: 2), 3)
    }

    func testAdaptiveMaxDistance() {
        XCTAssertEqual(TypoDistance.maxDistance(forQueryLength: 1), 0)
        XCTAssertEqual(TypoDistance.maxDistance(forQueryLength: 3), 0)
        XCTAssertEqual(TypoDistance.maxDistance(forQueryLength: 4), 1)
        XCTAssertEqual(TypoDistance.maxDistance(forQueryLength: 6), 1)
        XCTAssertEqual(TypoDistance.maxDistance(forQueryLength: 7), 2)
        XCTAssertEqual(TypoDistance.maxDistance(forQueryLength: 12), 2)
    }

    func testPrefixDistance() {
        // Exact prefix
        XCTAssertEqual(TypoDistance.prefixDistance(query: "ang", candidate: "angst"), 0)

        // Prefix with typo (query "enemise" matching prefix of "enemies")
        XCTAssertEqual(TypoDistance.prefixDistance(query: "enemise", candidate: "enemies"), 1)

        // Short queries require exact prefix
        XCTAssertEqual(TypoDistance.prefixDistance(query: "anx", candidate: "angst"), 3)
    }
}
