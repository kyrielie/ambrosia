import XCTest
@testable import Ambrosia

// Covers LRUCache<Key, Value> in CacheTypes.swift, which backs
// filterResultCache/pageCache/countCache (see docs/caching.md). Pure value
// type, no actor dependency -- driven directly.
final class LRUCacheTests: XCTestCase {

    func test_setAndGet_roundTrips() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache.set(1, for: "a")
        XCTAssertEqual(cache["a"], 1)
        XCTAssertEqual(cache.count, 1)
    }

    func test_missingKey_returnsNil() {
        let cache = LRUCache<String, Int>(limit: 3)
        XCTAssertNil(cache["missing"])
    }

    func test_evictsOldestInsertion_whenOverLimit() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        cache.set(3, for: "c") // "a" was the oldest insertion, should be evicted

        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2)
    }

    func test_reSetOnExistingKey_refreshesItsPosition() {
        // Re-inserting an existing key moves it to the back of `order`
        // (LRUCache.set: "Refresh: remove from current position, append to
        // back"), so it should survive the next eviction instead of "a".
        var cache = LRUCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        cache.set(10, for: "a") // refresh "a" -- "b" is now the oldest
        cache.set(3, for: "c")  // should evict "b", not "a"

        XCTAssertEqual(cache["a"], 10)
        XCTAssertNil(cache["b"])
        XCTAssertEqual(cache["c"], 3)
    }

    func test_get_doesNotRefreshPosition() {
        // LRUCache's eviction is insertion-order, not access-order: reading
        // a key via the subscript getter does not move it to the back of
        // `order` -- only `set` does (see CacheTypes.swift; there is no
        // `mutating get` that could touch `order`). This is worth locking
        // down explicitly since "LRU" as a name suggests access-order
        // (true least-recently-*used*) eviction to a future reader, and a
        // fix that made `get` non-mutating-but-refreshing would need a
        // deliberate design change (subscript get can't mutate `order`
        // without becoming a mutating subscript), not an accidental one.
        var cache = LRUCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        _ = cache["a"] // read, but does NOT refresh "a"'s position
        cache.set(3, for: "c") // "a" is still the oldest insertion -> evicted

        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache["c"], 3)
    }

    func test_removeAll_clearsEverything() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        cache.removeAll()

        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache["a"])
        XCTAssertNil(cache["b"])
    }

    func test_limitOne_evictsPreviousEntryImmediately() {
        var cache = LRUCache<String, Int>(limit: 1)
        cache.set(1, for: "a")
        cache.set(2, for: "b")

        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache.count, 1)
    }
}

// Covers FilterResultCacheKey/PageCacheKey/CountCacheKey/tagExpansionsDigest,
// the cache-key shaping logic that sits next to LRUCache in CacheTypes.swift.
final class CacheKeyTests: XCTestCase {

    func test_tagExpansionsDigest_isOrderIndependentOnKeysAndValues() {
        let dictA: [String: [String]] = ["fluff": ["comfort", "cozy"], "angst": ["hurt"]]
        let dictB: [String: [String]] = ["angst": ["hurt"], "fluff": ["cozy", "comfort"]]
        XCTAssertEqual(tagExpansionsDigest(dictA), tagExpansionsDigest(dictB))
    }

    func test_tagExpansionsDigest_differsWhenValuesActuallyDiffer() {
        let dictA: [String: [String]] = ["fluff": ["comfort"]]
        let dictB: [String: [String]] = ["fluff": ["comfort", "cozy"]]
        XCTAssertNotEqual(tagExpansionsDigest(dictA), tagExpansionsDigest(dictB))
    }

    func test_filterResultCacheKey_sameRulesDifferentMembershipVersion_areNotEqual() {
        // FilterExpression only declares a no-arg init(), so its default
        // memberwise init isn't synthesized -- build via the default init
        // then assign the `var` properties, matching FilterExpression's own
        // shape in FilterRule.swift.
        var expression = FilterExpression()
        expression.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .equals, value: "fluff")], conjunction: .and)]
        expression.groupConjunction = .and

        let keyV1 = FilterResultCacheKey(expression: expression, membershipVersion: 1)
        let keyV2 = FilterResultCacheKey(expression: expression, membershipVersion: 2)
        XCTAssertNotEqual(keyV1, keyV2)
    }
}
