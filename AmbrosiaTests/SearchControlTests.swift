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
}
