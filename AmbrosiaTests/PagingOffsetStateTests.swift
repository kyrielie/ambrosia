import XCTest
@testable import Ambrosia

// Covers PagingOffsetState.commitNewPage, the idempotent commit used by the
// grouped drain branches of LibraryRootView.loadPage. Overlapping loads of the
// same page used to append twice and desync rawSQLOffsetByPage from currentPage.
final class PagingOffsetStateTests: XCTestCase {

    private func book(_ id: Int) -> CalibreBook {
        CalibreBook(
            id: id, title: "Book \(id)", series: nil, seriesIndex: nil,
            wordCount: nil, kudos: nil, publishedDate: nil, publisher: nil,
            relativePath: "Author/Book \(id)", authors: [], tags: [], comment: nil
        )
    }

    func testTwoCommitsForPageZeroRecordOnce() {
        var state = PagingOffsetState()
        state.commitNewPage(page: 0, startOffset: 0, newFrontier: 76, overflow: [book(1)])
        state.commitNewPage(page: 0, startOffset: 0, newFrontier: 152, overflow: [book(2)])
        XCTAssertEqual(state.rawSQLOffsetByPage, [0])
        XCTAssertEqual(state.seedOverflowByPage.count, 1)
        XCTAssertEqual(state.rawSQLOffsetFrontier, 76)
        XCTAssertEqual(state.rawSQLOffsetOverflowFrontier.map(\.id), [1])
    }

    func testNextPageAppendsAndAdvancesFrontier() {
        var state = PagingOffsetState()
        state.commitNewPage(page: 0, startOffset: 0, newFrontier: 76, overflow: [book(1)])
        state.currentPage = 1
        state.commitNewPage(page: 1, startOffset: 76, newFrontier: 140, overflow: [])
        XCTAssertEqual(state.rawSQLOffsetByPage, [0, 76])
        XCTAssertEqual(state.rawSQLOffsetFrontier, 140)
        XCTAssertEqual(state.seedOverflowByPage[1].map(\.id), [1])
        XCTAssertTrue(state.rawSQLOffsetOverflowFrontier.isEmpty)
    }

    func testStaleCommitAfterResetIsNoOp() {
        var state = PagingOffsetState()
        state.commitNewPage(page: 0, startOffset: 0, newFrontier: 76, overflow: [])
        state.currentPage = 1
        // A load for page 1 starts, then the filter changes before it commits.
        state.resetForNewFilter()
        state.commitNewPage(page: 1, startOffset: 76, newFrontier: 140, overflow: [])
        XCTAssertTrue(state.rawSQLOffsetByPage.isEmpty)
        XCTAssertEqual(state.rawSQLOffsetFrontier, 0)
    }

    func testCommitForNonCurrentPageIsNoOp() {
        var state = PagingOffsetState()
        state.currentPage = 0
        state.commitNewPage(page: 1, startOffset: 5, newFrontier: 10, overflow: [])
        XCTAssertTrue(state.rawSQLOffsetByPage.isEmpty)
    }
}
