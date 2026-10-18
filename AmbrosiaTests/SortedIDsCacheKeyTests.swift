import XCTest
@testable import Ambrosia

// The sorted-id cache must be shared across pages of one view and never
// across views. These pin both halves, plus the true-LRU read it relies on.
final class SortedIDsCacheKeyTests: XCTestCase {

    private func key(query: String = "q", filter: String = "f", expansions: String = "",
                     version: Int = 1, signature: String = "s", sort: SortField = .title,
                     ascending: Bool = true, seed: UInt64 = 1) -> SortedIDsCacheKey {
        SortedIDsCacheKey(querySignature: query, filterSignature: filter, tagExpansionsDigest: expansions,
                          visibilityVersion: version, visibilitySignature: signature, sortField: sort,
                          ascending: ascending, randomSeed: seed)
    }

    private func page(offset: Int, limit: Int) -> PageCacheKey {
        PageCacheKey(querySignature: "q", filterSignature: "f", tagExpansionsDigest: "",
                     visibilityVersion: 1, visibilitySignature: "s", sortField: .title,
                     ascending: true, randomSeed: 1, offset: offset, limit: limit)
    }

    func testPageKeysDifferingOnlyInWindowShareOneSortedKey() {
        let first = page(offset: 0, limit: 25)
        let second = page(offset: 25, limit: 25)
        let third = page(offset: 0, limit: 76)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.sortedKey, second.sortedKey)
        XCTAssertEqual(first.sortedKey, third.sortedKey)
        XCTAssertEqual(first.sortedKey, key())
    }

    func testKeyChangesWithEachInput() {
        let base = key()
        let variants = [
            key(query: "other"), key(filter: "other"), key(expansions: "a:[b]"), key(version: 2),
            key(signature: "other"), key(sort: .wordCount), key(ascending: false), key(seed: 2)
        ]
        for variant in variants { XCTAssertNotEqual(base, variant) }
        XCTAssertEqual(Set(variants + [base]).count, variants.count + 1)
    }

    func testIdenticalInputsAreEqualAndHashEqual() {
        XCTAssertEqual(key(), key())
        XCTAssertEqual(key().hashValue, key().hashValue)
    }

    func testGetRefreshesRecencyButSubscriptDoesNot() {
        var viaGet = LRUCache<String, Int>(limit: 2)
        viaGet.set(1, for: "a")
        viaGet.set(2, for: "b")
        XCTAssertEqual(viaGet.get("a"), 1)
        viaGet.set(3, for: "c")            // evicts "b", the least recently used
        XCTAssertEqual(viaGet.get("a"), 1)
        XCTAssertNil(viaGet.get("b"))

        var viaSubscript = LRUCache<String, Int>(limit: 2)
        viaSubscript.set(1, for: "a")
        viaSubscript.set(2, for: "b")
        XCTAssertEqual(viaSubscript["a"], 1)
        viaSubscript.set(3, for: "c")      // insertion order: evicts "a"
        XCTAssertNil(viaSubscript["a"])
    }

    func testGetMissReturnsNilAndDoesNotChangeCount() {
        var cache = LRUCache<String, Int>(limit: 2)
        XCTAssertNil(cache.get("missing"))
        XCTAssertEqual(cache.count, 0)
    }
}
