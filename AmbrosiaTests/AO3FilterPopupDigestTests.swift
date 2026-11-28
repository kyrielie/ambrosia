import XCTest
@testable import Ambrosia

@MainActor
final class AO3FilterPopupDigestTests: XCTestCase {

    func testIdenticalToolbarStatesProduceSameDigest() {
        let stateA = LibraryToolbarState()
        let stateB = LibraryToolbarState()
        XCTAssertEqual(
            AO3FilterPopupDigest.current(toolbarState: stateA),
            AO3FilterPopupDigest.current(toolbarState: stateB)
        )
    }

    func testSearchTextChangeChangesDigest() {
        let state = LibraryToolbarState()
        let baseline = AO3FilterPopupDigest.current(toolbarState: state)

        state.searchText = "angst"
        let updated = AO3FilterPopupDigest.current(toolbarState: state)

        XCTAssertNotEqual(baseline, updated)
    }

    func testFilterExpressionChangeChangesDigest() {
        let state = LibraryToolbarState()
        let baseline = AO3FilterPopupDigest.current(toolbarState: state)

        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .equals, value: "Fluff")])]
        state.filterExpression = expr
        let updated = AO3FilterPopupDigest.current(toolbarState: state)

        XCTAssertNotEqual(baseline, updated)
    }

    func testSortChangeDoesNotChangeDigest() {
        let state = LibraryToolbarState()
        let baseline = AO3FilterPopupDigest.current(toolbarState: state)

        state.sortField = .wordCount
        state.ascending = false
        let updated = AO3FilterPopupDigest.current(toolbarState: state)

        XCTAssertEqual(baseline, updated)
    }
}
