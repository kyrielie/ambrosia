import XCTest
@testable import Ambrosia

/// `RowClickPolicy` (`BookListRow.swift`): row controls act on the first click
/// of a multi-click only, so a double-click on a tag pill or author applies
/// its filter once and a double-click on the title opens once.
final class RowClickPolicyTests: XCTestCase {
    func testFirstClickIsHandled() {
        XCTAssertTrue(RowClickPolicy.shouldHandle(clickCount: 1))
    }

    func testRepeatClicksAreIgnored() {
        XCTAssertFalse(RowClickPolicy.shouldHandle(clickCount: 2))
        XCTAssertFalse(RowClickPolicy.shouldHandle(clickCount: 3))
    }

    func testZeroClickCountIsHandled() {
        // Synthetic or non-mouse activation reports no click count.
        XCTAssertTrue(RowClickPolicy.shouldHandle(clickCount: 0))
    }
}
