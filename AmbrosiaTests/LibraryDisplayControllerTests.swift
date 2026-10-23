import XCTest
@testable import Ambrosia

@MainActor
final class LibraryDisplayControllerTests: XCTestCase {

    private var libraryURL: URL!
    private var session: LibrarySession!
    private var toolbarState: LibraryToolbarState!
    private var controller: LibraryDisplayController!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayControllerTests-\(UUID().uuidString)")
        session = LibrarySession()
        toolbarState = LibraryToolbarState()
        controller = LibraryDisplayController(session: session, toolbarState: toolbarState)
    }

    override func tearDownWithError() throws {
        controller = nil
        toolbarState = nil
        session = nil
        libraryURL = nil
    }

    func testInitialState() {
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertTrue(controller.books.isEmpty)
        XCTAssertEqual(controller.offsetState.currentPage, 0)
        XCTAssertFalse(controller.hasNextPage)
        XCTAssertFalse(controller.hasPreviousPage)
        XCTAssertNil(controller.selectedItemID)
        XCTAssertNil(controller.selectedBook)
        XCTAssertFalse(controller.isLoading)
        XCTAssertFalse(controller.didFinishFirstLoad)
    }

    func testSelectionResolution() {
        let book1 = CalibreBook(
            id: 1,
            title: "First Book",
            series: nil,
            seriesIndex: nil,
            wordCount: 5000,
            kudos: 100,
            publishedDate: nil,
            publisher: nil,
            relativePath: "Author A/First Book (1)",
            authors: ["Author A"],
            tags: ["Fiction"],
            comment: nil
        )
        let item1 = LibraryItem.book(book1)

        // Inject selection when not in items
        controller.selectedItemID = item1.id
        XCTAssertNil(controller.selectedBook)
    }

    func testPageOffsetBounds() {
        XCTAssertEqual(controller.offsetState.currentPage, 0)
        XCTAssertFalse(controller.hasPreviousPage)

        // previousPage at 0 is a no-op
        controller.previousPage()
        XCTAssertEqual(controller.offsetState.currentPage, 0)
        XCTAssertFalse(controller.hasPreviousPage)
    }

    func testVisibilityPolicyDerivation() {
        toolbarState.groupBySeries = true
        ReaderPreferences.shared.showSkippedCollection = true

        let policy = controller.currentVisibilityPolicy
        XCTAssertTrue(policy.shouldGroupSeriesRows)
        XCTAssertTrue(policy.showSkippedCollection)
    }

    func testFilterRuleAddOrReplace() {
        let rule1 = FilterRule(field: .authorName, op: .equals, value: "Jane Austen")
        controller.addOrReplaceRule(rule1)

        XCTAssertTrue(toolbarState.filterExpression.hasCompleteRules)
        let rules = toolbarState.filterExpression.groups.flatMap(\.rules)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.value, "Jane Austen")

        // Replace with new author
        let rule2 = FilterRule(field: .authorName, op: .equals, value: "Mary Shelley")
        controller.addOrReplaceRule(rule2)

        let updatedRules = toolbarState.filterExpression.groups.flatMap(\.rules)
        XCTAssertEqual(updatedRules.count, 1)
        XCTAssertEqual(updatedRules.first?.value, "Mary Shelley")
    }

    func testActiveFullTextPhraseExtraction() {
        toolbarState.searchText = "plain search"
        XCTAssertNil(controller.activeFullTextPhrase)

        toolbarState.searchText = "fulltext:exact phrase"
        XCTAssertEqual(controller.activeFullTextPhrase, "exact phrase")
    }
}
