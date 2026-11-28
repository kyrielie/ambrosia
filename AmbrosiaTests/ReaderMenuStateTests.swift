import XCTest
@testable import Ambrosia

@MainActor
final class ReaderMenuStateTests: XCTestCase {

    func testDefaultStateAndUpdates() {
        let state = ReaderMenuState()
        XCTAssertFalse(state.isReaderFocused)
        XCTAssertFalse(state.canGoPreviousPage)
        XCTAssertFalse(state.canGoNextPage)
        XCTAssertFalse(state.canGoPreviousChapter)
        XCTAssertFalse(state.canGoNextChapter)
        XCTAssertFalse(state.isCurrentWorkLiked)
        XCTAssertFalse(state.isCurrentWorkInReadLater)
        XCTAssertFalse(state.isSeriesReader)
        XCTAssertEqual(state.seriesLikeState, .none)
        XCTAssertEqual(state.seriesReadLaterState, .none)
        XCTAssertEqual(state.libraryViewMode, .list)

        state.isReaderFocused = true
        state.isSeriesReader = true
        state.seriesLikeState = .partial
        state.libraryViewMode = .email

        XCTAssertTrue(state.isReaderFocused)
        XCTAssertTrue(state.isSeriesReader)
        XCTAssertEqual(state.seriesLikeState, .partial)
        XCTAssertEqual(state.libraryViewMode, .email)
    }
}
