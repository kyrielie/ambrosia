import XCTest
@testable import Ambrosia

/// Coverage for the free helper functions in `FlowLayout.swift` (81-131)
/// shared by `LibraryRootView.rebuildItems` and
/// `EmailLibraryViewController.rebuildSidebarItems` for series grouping/
/// leadership. None of these are mentioned in either doc's gap list and had
/// zero coverage of their own before this file.
final class SeriesHelpersTests: XCTestCase {

    // MARK: - missingIndices(in:)

    func testMissingIndicesFindsGap() {
        XCTAssertEqual(missingIndices(in: [1, 2, 4, 5]), [3])
    }

    func testMissingIndicesContiguousInputReturnsEmpty() {
        XCTAssertEqual(missingIndices(in: [1, 2, 3, 4]), [])
    }

    func testMissingIndicesEmptyInputReturnsEmpty() {
        XCTAssertEqual(missingIndices(in: []), [])
    }

    func testMissingIndicesDeduplicatesInput() {
        // Set-based dedup means a repeated present index doesn't spuriously
        // appear as "missing" or double-count; the gap logic is unaffected.
        XCTAssertEqual(missingIndices(in: [1, 1, 2, 4, 4, 5]), [3])
    }

    func testMissingIndicesUnsortedInputIsSortedFirst() {
        XCTAssertEqual(missingIndices(in: [5, 1, 4, 2]), [3])
    }

    func testMissingIndicesSingleElementAtOneReturnsEmpty() {
        // last == 1 fails the `last > 1` guard, so a single "1" produces no gaps.
        XCTAssertEqual(missingIndices(in: [1]), [])
    }

    func testMissingIndicesStartingAboveOneFillsFromOne() {
        // The range scanned is always 1...last, not min...last, so indices
        // below the lowest present value are reported missing too.
        XCTAssertEqual(missingIndices(in: [3, 4]), [1, 2])
    }

    // MARK: - parseISODate(_:)

    func testParseISODateValidISO8601String() {
        let result = parseISODate("2024-03-15T10:30:00Z")
        XCTAssertNotNil(result)
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: result!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 15)
    }

    func testParseISODateNilInputReturnsNil() {
        XCTAssertNil(parseISODate(nil))
    }

    func testParseISODateEmptyStringReturnsNil() {
        XCTAssertNil(parseISODate(""))
    }

    func testParseISODateFallsBackToYYYYMMDD() {
        let result = parseISODate("2024-03-15")
        XCTAssertNotNil(result)
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: result!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 15)
    }

    func testParseISODateMalformedStringReturnsNil() {
        XCTAssertNil(parseISODate("not a date"))
    }

    // MARK: - sortedSeriesEntries(_:)

    func testSortedSeriesEntriesOrdersBySeriesIndexThenCalibreID() {
        let entries = [
            makeEntry(calibreID: 3, seriesIndex: 1),
            makeEntry(calibreID: 1, seriesIndex: 2),
            makeEntry(calibreID: 2, seriesIndex: 1) // ties with calibreID: 3 on seriesIndex
        ]
        let sorted = sortedSeriesEntries(entries)
        XCTAssertEqual(sorted.map(\.calibreID), [2, 3, 1])
    }

    // MARK: - sortedSeriesWorks(_:using:)

    func testSortedSeriesWorksUsesEntrySeriesIndexTieBrokenByID() {
        let works = [
            makeBook(id: 3),
            makeBook(id: 1),
            makeBook(id: 2)
        ]
        let entries = [
            makeEntry(calibreID: 3, seriesIndex: 1),
            makeEntry(calibreID: 1, seriesIndex: 2),
            makeEntry(calibreID: 2, seriesIndex: 1)
        ]
        let sortedEntries = sortedSeriesEntries(entries)
        let sortedWorks = sortedSeriesWorks(works, using: sortedEntries)
        XCTAssertEqual(sortedWorks.map(\.id), [2, 3, 1])
    }

    func testSortedSeriesWorksTreatsMissingEntryAsIndexZero() {
        // A CalibreBook with no matching SeriesCacheEntry falls back to
        // seriesIndex 0, so it sorts before any work with a positive index.
        let works = [makeBook(id: 1), makeBook(id: 2)]
        let entries = [makeEntry(calibreID: 1, seriesIndex: 5)] // no entry for id 2
        let sortedWorks = sortedSeriesWorks(works, using: entries)
        XCTAssertEqual(sortedWorks.map(\.id), [2, 1])
    }

    // MARK: - Fixtures

    private func makeEntry(calibreID: Int, seriesIndex: Int) -> SeriesCacheEntry {
        SeriesCacheEntry(
            calibreID: calibreID,
            seriesName: "Test Series",
            seriesIndex: seriesIndex,
            ao3SeriesID: nil,
            isAnthology: false,
            calibreSeriesID: nil
        )
    }

    private func makeBook(id: Int) -> CalibreBook {
        CalibreBook(
            id: id,
            title: "Book \(id)",
            series: "Test Series",
            seriesIndex: nil,
            wordCount: nil,
            kudos: nil,
            publishedDate: nil,
            publisher: nil,
            relativePath: "path/\(id).epub"
        )
    }
}
