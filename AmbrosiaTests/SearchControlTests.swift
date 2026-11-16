// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class SearchControlTests: XCTestCase {

    func testBeginInvalidatesEarlierTokens() {
        let control = SearchControl(handle: nil)
        let first = control.begin()
        XCTAssertTrue(control.isCurrent(first))
        let second = control.begin()
        XCTAssertFalse(control.isCurrent(first))
        XCTAssertTrue(control.isCurrent(second))
        XCTAssertNotEqual(first, second)
    }

    func testCancelInvalidatesCurrentToken() {
        let control = SearchControl(handle: nil)
        let token = control.begin()
        control.cancel(token)
        XCTAssertFalse(control.isCurrent(token))
    }

    func testStaleCancelDoesNotAbortNewerSearch() {
        let control = SearchControl(handle: nil)
        let old = control.begin()
        let newer = control.begin()
        control.cancel(old)
        XCTAssertTrue(control.isCurrent(newer))
    }

    func testSwapToNilStillCountsGenerations() {
        let control = SearchControl(handle: nil)
        control.swap(handle: nil)
        let token = control.begin()
        XCTAssertTrue(control.isCurrent(token))
    }

    func testDefaultSearchSortToRelevanceAutoSwitchAndRestore() {
        let prefs = ReaderPreferences.shared
        let originalPref = prefs.defaultSearchSortToRelevance
        defer { prefs.defaultSearchSortToRelevance = originalPref }

        prefs.defaultSearchSortToRelevance = true
        let state = LibraryToolbarState()
        state.sortField = .kudos
        state.ascending = true

        // Setting a search query switches to relevance descending
        state.searchText = "angst"
        XCTAssertEqual(state.sortField, .relevance)
        XCTAssertFalse(state.ascending)

        // Clearing search query restores prior sort field and direction
        state.searchText = ""
        XCTAssertEqual(state.sortField, .kudos)
        XCTAssertTrue(state.ascending)

        // When pref is false, sort field is untouched
        prefs.defaultSearchSortToRelevance = false
        state.sortField = .author
        state.ascending = true
        state.searchText = "fluff"
        XCTAssertEqual(state.sortField, .author)
        XCTAssertTrue(state.ascending)
    }
}
