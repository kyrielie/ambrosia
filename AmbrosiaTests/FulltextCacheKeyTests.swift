// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

/// Cache-key rules for `fulltext:` phrases. The key comes from `FTSQuery.cacheKey`; the
/// query-level normalization tests live in `FTSQueryTests`.
final class FulltextCacheKeyTests: XCTestCase {

    private func key(_ text: String) -> String? { FTSQuery.make(text)?.cacheKey }

    func testAccentedAndPlainQueriesGetDifferentKeys() {
        XCTAssertNotEqual(key("resume"), key("r\u{00E9}sum\u{00E9}"))
    }

    func testCaseIsPreservedInKey() {
        XCTAssertNotEqual(key("AND"), key("and"))
    }

    func testEmptyAndWhitespaceInputHaveNoKey() {
        XCTAssertNil(key(""))
        XCTAssertNil(key(" \t\n"))
    }

    func testEquivalentInputsShareAKey() {
        XCTAssertEqual(key("  dragon \n"), key("dragon"))
        XCTAssertEqual(key("\u{FB01}nd"), key("find"))
    }

    func testFulltextMapCollapsesEqualKeysWithoutTrapping() throws {
        let map = LibraryQueryHelpers.fulltextMap(values: ["dragon", " dragon ", "dragon"]) { _ in [1, 2] }
        XCTAssertEqual(map.count, 1)
        let dragonKey = try XCTUnwrap(key("dragon"))
        XCTAssertEqual(map[dragonKey], [1, 2])
    }

    func testFulltextMapKeepsDistinctPhrasesAndMapsUncachedToEmpty() throws {
        let map = LibraryQueryHelpers.fulltextMap(values: ["resume", "r\u{00E9}sum\u{00E9}", ""]) { value in
            value == "resume" ? [7] : nil
        }
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[try XCTUnwrap(key("resume"))], [7])
        XCTAssertEqual(map[try XCTUnwrap(key("r\u{00E9}sum\u{00E9}"))], [])
    }
}
