import XCTest
@testable import Ambrosia

/// Coverage for `TagPillDisplay.capped(_:max:)` (`BookListRow.swift`).
final class TagPillCapTests: XCTestCase {

    private func pills(_ count: Int) -> [TagPillDisplay] {
        (0..<count).map { TagPillDisplay(label: "tag\($0)", field: .tag, role: .regular) }
    }

    func testUnderCapReturnsAllWithNoHidden() {
        let input = pills(3)
        let result = TagPillDisplay.capped(input, max: 5)
        XCTAssertEqual(result.shown, input)
        XCTAssertEqual(result.hiddenCount, 0)
    }

    func testAtCapReturnsAllWithNoHidden() {
        let input = pills(5)
        let result = TagPillDisplay.capped(input, max: 5)
        XCTAssertEqual(result.shown, input)
        XCTAssertEqual(result.hiddenCount, 0)
    }

    func testOverCapTruncatesAndCountsHidden() {
        let input = pills(8)
        let result = TagPillDisplay.capped(input, max: 5)
        XCTAssertEqual(result.shown.count, 5)
        XCTAssertEqual(result.hiddenCount, 3)
    }

    func testOrderIsPreserved() {
        let input = pills(8)
        let result = TagPillDisplay.capped(input, max: 5)
        XCTAssertEqual(result.shown.map(\.label), ["tag0", "tag1", "tag2", "tag3", "tag4"])
    }

    func testEmptyInput() {
        let result = TagPillDisplay.capped([], max: 5)
        XCTAssertTrue(result.shown.isEmpty)
        XCTAssertEqual(result.hiddenCount, 0)
    }
}
