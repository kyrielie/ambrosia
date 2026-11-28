import XCTest
@testable import Ambrosia

@MainActor
final class SearchActivityLogTests: XCTestCase {

    override func setUpWithError() throws {
        SearchActivityLog.shared.discardWithoutPersisting()
    }

    override func tearDownWithError() throws {
        SearchActivityLog.shared.discardWithoutPersisting()
    }

    func testIgnoresEmptySearchWithoutFilter() {
        SearchActivityLog.shared.append(searchText: "   \n\t ", filterExpression: nil, resultCount: 10)
        XCTAssertTrue(SearchActivityLog.shared.entries.isEmpty)
    }

    func testAppendsTrimmedSearchAndDeduplicatesConsecutiveIdentical() {
        SearchActivityLog.shared.append(searchText: "  slow burn  ", filterExpression: nil, resultCount: 42)
        SearchActivityLog.shared.append(searchText: "slow burn", filterExpression: nil, resultCount: 42)

        XCTAssertEqual(SearchActivityLog.shared.entries.count, 1)
        XCTAssertEqual(SearchActivityLog.shared.entries.first?.searchText, "slow burn")
        XCTAssertEqual(SearchActivityLog.shared.entries.first?.resultCount, 42)
    }

    func testDoesNotDeduplicateWhenFilterExpressionDiffers() {
        var expr1 = FilterExpression()
        expr1.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .equals, value: "Fluff")])]

        var expr2 = FilterExpression()
        expr2.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .equals, value: "Angst")])]

        SearchActivityLog.shared.append(searchText: "", filterExpression: expr1, resultCount: 5)
        SearchActivityLog.shared.append(searchText: "", filterExpression: expr2, resultCount: 5)

        XCTAssertEqual(SearchActivityLog.shared.entries.count, 2)
    }

    func testCapacityCapsAt200Entries() {
        for idx in 1...205 {
            SearchActivityLog.shared.append(searchText: "query-\(idx)", filterExpression: nil, resultCount: idx)
        }

        XCTAssertEqual(SearchActivityLog.shared.entries.count, 200)
        XCTAssertEqual(SearchActivityLog.shared.entries.first?.searchText, "query-6")
        XCTAssertEqual(SearchActivityLog.shared.entries.last?.searchText, "query-205")
    }
}
