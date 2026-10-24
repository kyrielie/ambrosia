import XCTest
@testable import Ambrosia

final class ReaderControlsTests: XCTestCase {

    func testTOCPopupViewControllerConfiguration() {
        let tocVC = TOCPopupViewController()
        _ = tocVC.view

        let entries: [TOCPanelEntry] = [
            TOCPanelEntry(id: "1", title: "Chapter 1: The Beginning", spineIndex: 0, depth: 0, fragment: nil),
            TOCPanelEntry(id: "2", title: "Chapter 2: The Middle", spineIndex: 1, depth: 0, fragment: nil),
            TOCPanelEntry(id: "3", title: "Chapter 3: The End", spineIndex: 2, depth: 0, fragment: "anchor")
        ]

        var selectedEntry: TOCPanelEntry?
        tocVC.onSelect = { entry in
            selectedEntry = entry
        }
        tocVC.configure(entries: entries, currentSpineIndex: 1)

        XCTAssertNotNil(tocVC.view)
        XCTAssertNil(selectedEntry)
    }

    func testSearchBarViewControllerResultsAndStepping() {
        let searchVC = SearchBarViewController()
        _ = searchVC.view

        let results: [BookSearchResult] = [
            BookSearchResult(spineIndex: 0, characterOffset: 12, excerpt: "First match excerpt"),
            BookSearchResult(spineIndex: 1, characterOffset: 45, excerpt: "Second match excerpt")
        ]
        let chapterTitles: [Int: String] = [0: "Chapter 1", 1: "Chapter 2"]

        searchVC.showResults(results, chapterTitles: chapterTitles)
        XCTAssertEqual(searchVC.numberOfRows(in: NSTableView()), 2)

        searchVC.selectResult(at: 1)
        searchVC.stepResult(by: -1)

        searchVC.clear()
        XCTAssertEqual(searchVC.numberOfRows(in: NSTableView()), 0)
    }

    func testTOCSidebarViewInitialization() {
        let entries: [TOCPanelEntry] = [
            TOCPanelEntry(id: "1", title: "Chapter 1", spineIndex: 0, depth: 0, workTitle: "Work 1", fragment: nil),
            TOCPanelEntry(id: "2", title: "Chapter 2", spineIndex: 1, depth: 0, workTitle: "Work 2", fragment: nil)
        ]
        var jumped = false
        let sidebar = TOCSidebarView(entries: entries, currentSpineIndex: 0) { _ in
            jumped = true
        }
        XCTAssertNotNil(sidebar.body)
        XCTAssertFalse(jumped)
    }
}
