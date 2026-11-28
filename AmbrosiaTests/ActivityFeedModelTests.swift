import XCTest
@testable import Ambrosia

final class ActivityFeedModelTests: XCTestCase {

    func testFilterTabsHaveUniqueIDsAndNonEmptyMessages() {
        let ids = ActivityFeedFilter.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ActivityFeedFilter.allCases.count)
        for filter in ActivityFeedFilter.allCases {
            XCTAssertFalse(filter.sfSymbol.isEmpty)
            XCTAssertFalse(filter.emptyStateSymbol.isEmpty)
            XCTAssertFalse(filter.emptyStateMessage.isEmpty)
        }
    }

    func testSearchActivityEntrySummaryWithTextOnly() {
        let entry = SearchActivityEntry(
            id: UUID(),
            date: Date(),
            searchText: "coffee shop",
            filterExpression: nil,
            resultCount: 12
        )
        XCTAssertFalse(entry.hasFilterRules)
        XCTAssertEqual(entry.displaySummary, "\u{201C}coffee shop\u{201D}")
    }

    func testSearchActivityEntrySummaryWithTextAndFilter() {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .equals, value: "Fluff")])]
        let entry = SearchActivityEntry(
            id: UUID(),
            date: Date(),
            searchText: "au",
            filterExpression: expr,
            resultCount: 3
        )
        XCTAssertTrue(entry.hasFilterRules)
        XCTAssertTrue(entry.displaySummary.contains("\u{201C}au\u{201D}"))
        XCTAssertTrue(entry.displaySummary.contains("·"))
        XCTAssertTrue(entry.displaySummary.contains("Fluff"))
    }

    func testActivityFeedEntrySearchCaseIDAndDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let uuid = UUID()
        let searchEntry = SearchActivityEntry(
            id: uuid,
            date: date,
            searchText: "test",
            filterExpression: nil,
            resultCount: 1
        )
        let feedEntry = ActivityFeedEntry.search(searchEntry)
        XCTAssertEqual(feedEntry.id, "q-\(uuid.uuidString)")
        XCTAssertEqual(feedEntry.date, date)
    }
}
