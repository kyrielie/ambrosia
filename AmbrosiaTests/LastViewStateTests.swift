import XCTest
@testable import Ambrosia

final class LastViewStateTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: LastViewStore!

    override func setUp() {
        super.setUp()
        suiteName = "LastViewStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = LastViewStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    private func expression(_ groups: [FilterGroup], groupConjunction: FilterConjunction = .or) -> FilterExpression {
        var expression = FilterExpression()
        expression.groups = groups
        expression.groupConjunction = groupConjunction
        return expression
    }

    private func tagRule(_ value: String = "fluff") -> FilterRule {
        FilterRule(field: .tag, op: .equals, value: value)
    }

    private func state(sort: SortField = .wordCount, ascending: Bool = false,
                       filter: FilterExpression? = nil) -> LastViewState {
        LastViewState(sortField: sort, ascending: ascending, filterExpression: filter)
    }

    // MARK: Persistence

    func testEncodeDecodeRoundTrip() throws {
        let original = state(filter: expression([FilterGroup(rules: [tagRule()], conjunction: .and)]))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LastViewState.self, from: data), original)
    }

    func testSaveThenLoadRoundTripsPerLibrary() {
        let saved = state(filter: expression([FilterGroup(rules: [tagRule()])]))
        store.save(saved, libraryHash: "aaaa")
        XCTAssertEqual(store.load(libraryHash: "aaaa"), saved)
        XCTAssertNil(store.load(libraryHash: "bbbb"))
    }

    func testSchemaVersionMismatchLoadsNothing() throws {
        var old = state()
        old.schemaVersion = LastViewState.currentSchemaVersion + 1
        defaults.set(try JSONEncoder().encode(old), forKey: LastViewStore.key(forLibraryHash: "aaaa"))
        XCTAssertNil(store.load(libraryHash: "aaaa"))
    }

    func testCorruptDataLoadsNothing() {
        defaults.set(Data("not json".utf8), forKey: LastViewStore.key(forLibraryHash: "aaaa"))
        XCTAssertNil(store.load(libraryHash: "aaaa"))
    }

    func testSavingTheDefaultViewRemovesTheStoredValue() {
        store.save(state(), libraryHash: "aaaa")
        XCTAssertNotNil(store.load(libraryHash: "aaaa"))
        store.save(.defaultView, libraryHash: "aaaa")
        XCTAssertNil(store.load(libraryHash: "aaaa"))
    }

    func testUnknownSortRawFallsBackToTitle() throws {
        var odd = state()
        odd.sortFieldRaw = "somethingNew"
        XCTAssertEqual(odd.sortField, .title)
        let result = LastViewValidator.validate(odd, collectionNames: nil)
        XCTAssertEqual(result.state.sortField, .title)
        XCTAssertEqual(result.dropped, ["sort:somethingNew"])
    }

    // MARK: Validation

    func testRuleForMissingCollectionIsDropped() {
        let rules = [FilterRule(field: .collection, op: .equals, value: "Gone"), tagRule()]
        let result = LastViewValidator.validate(
            state(filter: expression([FilterGroup(rules: rules)])), collectionNames: ["Liked"])
        XCTAssertEqual(result.state.filterExpression?.groups.first?.rules.map(\.field), [.tag])
        XCTAssertEqual(result.dropped, ["collection:Gone"])
    }

    func testRuleForExistingCollectionIsKept() {
        let rule = FilterRule(field: .collection, op: .equals, value: "Liked")
        let result = LastViewValidator.validate(
            state(filter: expression([FilterGroup(rules: [rule])])), collectionNames: ["Liked"])
        XCTAssertEqual(result.state.filterExpression?.groups.first?.rules.count, 1)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testNilCollectionNamesSkipsTheCollectionCheck() {
        let rule = FilterRule(field: .collection, op: .equals, value: "Anything")
        let result = LastViewValidator.validate(
            state(filter: expression([FilterGroup(rules: [rule])])), collectionNames: nil)
        XCTAssertEqual(result.state.filterExpression?.groups.first?.rules.count, 1)
    }

    func testFulltextRuleIsDropped() {
        let rules = [FilterRule(field: .fulltext, op: .contains, value: "dragon"), tagRule()]
        let result = LastViewValidator.validate(
            state(filter: expression([FilterGroup(rules: rules)])), collectionNames: nil)
        XCTAssertEqual(result.state.filterExpression?.groups.first?.rules.map(\.field), [.tag])
        XCTAssertEqual(result.dropped, ["fulltext:dragon"])
    }

    func testIncompleteRulesAreDroppedSilently() {
        let rules = [FilterRule(field: .tag, op: .equals, value: "  "), tagRule()]
        let result = LastViewValidator.validate(
            state(filter: expression([FilterGroup(rules: rules)])), collectionNames: nil)
        XCTAssertEqual(result.state.filterExpression?.groups.first?.rules.count, 1)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testAllInvalidExpressionBecomesNoFilter() {
        let rules = [FilterRule(field: .collection, op: .equals, value: "Gone"),
                     FilterRule(field: .fulltext, op: .contains, value: "x")]
        let result = LastViewValidator.validate(
            state(filter: expression([FilterGroup(rules: rules)])), collectionNames: [])
        XCTAssertNil(result.state.filterExpression)
        XCTAssertEqual(result.state.sortField, .wordCount, "sort and direction survive a dropped filter")
        XCTAssertFalse(result.state.ascending)
    }

    func testEmptyGroupsAreRemovedAndConjunctionsPreserved() {
        let emptied = FilterGroup(rules: [FilterRule(field: .collection, op: .equals, value: "Gone")], conjunction: .or)
        let kept = FilterGroup(rules: [tagRule("a"), tagRule("b")], conjunction: .or)
        let result = LastViewValidator.validate(
            state(filter: expression([emptied, kept], groupConjunction: .and)), collectionNames: [])
        let validated = result.state.filterExpression
        XCTAssertEqual(validated?.groups.count, 1)
        XCTAssertEqual(validated?.groups.first?.conjunction, .or)
        XCTAssertEqual(validated?.groupConjunction, .and)
        XCTAssertEqual(validated?.groups.first?.id, kept.id)
    }

    // MARK: Restore

    func testRestoreReturnsNilWhenNothingStored() {
        XCTAssertNil(store.restore(libraryHash: "aaaa", collectionNames: []))
    }

    func testRestoreReturnsValidatedState() {
        let rules = [FilterRule(field: .collection, op: .equals, value: "Gone"), tagRule()]
        store.save(state(filter: expression([FilterGroup(rules: rules)])), libraryHash: "aaaa")
        let restored = store.restore(libraryHash: "aaaa", collectionNames: ["Liked"])
        XCTAssertEqual(restored?.state.filterExpression?.groups.first?.rules.map(\.field), [.tag])
        XCTAssertEqual(restored?.dropped, ["collection:Gone"])
    }

    func testRestoreReducingToDefaultViewReturnsNil() {
        let rule = FilterRule(field: .collection, op: .equals, value: "Gone")
        store.save(LastViewState(sortField: .title, ascending: true,
                                 filterExpression: expression([FilterGroup(rules: [rule])])),
                   libraryHash: "aaaa")
        XCTAssertNil(store.restore(libraryHash: "aaaa", collectionNames: []))
    }

    func testIsDefaultViewOnlyForTitleAscendingNoFilter() {
        XCTAssertTrue(LastViewState.defaultView.isDefaultView)
        XCTAssertFalse(state(sort: .title, ascending: false).isDefaultView)
        XCTAssertFalse(state(sort: .kudos, ascending: true).isDefaultView)
        XCTAssertFalse(state(sort: .title, ascending: true,
                             filter: expression([FilterGroup(rules: [tagRule()])])).isDefaultView)
    }
}
