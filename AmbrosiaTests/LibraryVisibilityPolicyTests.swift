import XCTest
@testable import Ambrosia

// NOTE: this file needs a Unit Testing Bundle target added in Xcode
// (File > New > Target > Unit Testing Bundle, name it AmbrosiaTests,
// add this file to it) before `xcodebuild test` will pick it up. Adding
// that target isn't something I can do safely by hand-editing
// project.pbxproj outside Xcode, so this is written and ready but not
// yet wired in.

final class LibraryVisibilityPolicyTests: XCTestCase {

    // MARK: - isVisible(_ id:)

    func test_allowAll_showsEverything() {
        let policy = LibraryVisibilityPolicy.allowAll
        XCTAssertTrue(policy.isVisible(1))
        XCTAssertTrue(policy.isVisible(999))
    }

    func test_skippedID_hiddenUnlessShowSkippedCollection() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.showSkippedCollection = false
        policy.skippedIDs = [42]

        XCTAssertFalse(policy.isVisible(42), "skipped ID should be hidden")
        XCTAssertTrue(policy.isVisible(43), "non-skipped ID should still show")

        policy.showSkippedCollection = true
        XCTAssertTrue(policy.isVisible(42), "toggling showSkippedCollection back on should reveal it")
    }

    func test_seriesOrMergedID_onlyHiddenWhenGroupingActive() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.seriesOrMergedIDs = [7]

        // Grouping off: a book that's rn=1 in one series and rn>1 in another
        // (multi-series membership) must still show as a singleton row.
        policy.shouldGroupSeriesRows = false
        XCTAssertTrue(policy.isVisible(7))

        policy.shouldGroupSeriesRows = true
        XCTAssertFalse(policy.isVisible(7))
    }

    func test_ao3PublisherOnly_isAnAllowList() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.hideNonAO3PublisherBooks = true
        policy.ao3PublisherIDs = [1, 2, 3]

        XCTAssertTrue(policy.isVisible(1))
        XCTAssertFalse(policy.isVisible(4), "not in the AO3-publisher allow-list, should be hidden")

        policy.hideNonAO3PublisherBooks = false
        XCTAssertTrue(policy.isVisible(4), "toggle off should stop restricting to the allow-list")
    }

    func test_anthology_isADenyList() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.hideAnthologyBooks = true
        policy.anthologyIDs = [91393]

        XCTAssertFalse(policy.isVisible(91393))
        XCTAssertTrue(policy.isVisible(1))

        policy.hideAnthologyBooks = false
        XCTAssertTrue(policy.isVisible(91393))
    }

    func test_allExclusionsCombine() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.showSkippedCollection = false
        policy.shouldGroupSeriesRows = true
        policy.hideNonAO3PublisherBooks = true
        policy.hideAnthologyBooks = true
        policy.skippedIDs = [1]
        policy.seriesOrMergedIDs = [2]
        policy.ao3PublisherIDs = [3, 4]
        policy.anthologyIDs = [4]

        XCTAssertFalse(policy.isVisible(1), "skipped")
        XCTAssertFalse(policy.isVisible(2), "collapsed series member")
        XCTAssertFalse(policy.isVisible(4), "AO3 publisher AND anthology — anthology deny-list wins")
        XCTAssertTrue(policy.isVisible(3), "AO3 publisher, not anthology — should show")
        XCTAssertFalse(policy.isVisible(5), "not in AO3-publisher allow-list")
    }

    // MARK: - filter(_ ids:)

    func test_filterIDs_matchesPerElementIsVisible() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.hideAnthologyBooks = true
        policy.anthologyIDs = [91393]

        let result = policy.filter([1, 2, 91393, 3])
        XCTAssertEqual(result, [1, 2, 3])
    }

    // MARK: - isVisible(_ book:) / filter(_ books:)

    private func makeBook(
        id: Int,
        publisher: String? = "Archive of Our Own",
        comment: String? = nil
    ) -> CalibreBook {
        var book = CalibreBook(
            id: id, title: "Test Book \(id)", series: nil, seriesIndex: nil,
            wordCount: nil, kudos: nil, publishedDate: nil,
            publisher: publisher, relativePath: ""
        )
        book.comment = comment
        return book
    }

    func test_isVisible_book_matchesIsVisible_id_forAO3PublisherAndAnthology() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.hideNonAO3PublisherBooks = true
        policy.hideAnthologyBooks = true
        policy.ao3PublisherIDs = [1, 2]
        policy.anthologyIDs = [2]

        let nonAO3 = makeBook(id: 3, publisher: "Some Other Press")
        XCTAssertFalse(policy.isVisible(nonAO3), "not AO3-published, allow-list should exclude it")
        XCTAssertEqual(policy.isVisible(nonAO3), policy.isVisible(3))

        let anthology = makeBook(
            id: 2, publisher: "Archive of Our Own",
            comment: "<p>Anthology containing:</p><div>...</div>"
        )
        XCTAssertFalse(policy.isVisible(anthology), "AO3-published but anthology comment should still be excluded")
        XCTAssertEqual(policy.isVisible(anthology), policy.isVisible(2))

        let realWork = makeBook(id: 1, publisher: "Archive of Our Own", comment: "A perfectly normal fic.")
        XCTAssertTrue(policy.isVisible(realWork))
        XCTAssertEqual(policy.isVisible(realWork), policy.isVisible(1))
    }

    func test_filterBooks_matchesPerElementIsVisible() {
        var policy = LibraryVisibilityPolicy.allowAll
        policy.hideAnthologyBooks = true
        policy.anthologyIDs = [2]

        let books = [
            makeBook(id: 1, comment: "Normal fic."),
            makeBook(id: 2, comment: "<p>Anthology containing:</p>"),
            makeBook(id: 3, comment: nil)
        ]
        let visible = policy.filter(books)
        XCTAssertEqual(visible.map(\.id), [1, 3])
    }
}
