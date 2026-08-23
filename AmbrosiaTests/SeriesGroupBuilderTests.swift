import XCTest
@testable import Ambrosia

/// Coverage for `buildSeriesGroups` (`Ambrosia/LibraryUI/SeriesGroupBuilder.swift`).
/// Pure function -- inputs are real `CalibreBook`/`SeriesCacheEntry`/
/// `AO3MetadataRecord` structs constructed by hand, no SQL or actor involved.
///
/// Note: `CalibreBook.displayComment`/`.isDescriptionAnthology` read
/// `ReaderPreferences.shared.correctCalibreAmpEntities` (a singleton).
/// Harmless with default state; every fixture book below either has no
/// comment or a comment with no `&amp;` entity, so this dependency never
/// changes any assertion's outcome.
final class SeriesGroupBuilderTests: XCTestCase {

    // MARK: - Normal 3-work series

    func testNormalThreeWorkSeriesProducesOneGroupWithUnionedMetadata() throws {
        let works = [
            makeBook(id: 1, tags: ["Fantasy", "Explicit"]),
            makeBook(id: 2, tags: ["Fantasy", "Angst"]),
            makeBook(id: 3, tags: ["Romance"])
        ]
        let entries = [
            makeEntry(calibreID: 1, seriesIndex: 1),
            makeEntry(calibreID: 2, seriesIndex: 2),
            makeEntry(calibreID: 3, seriesIndex: 3)
        ]
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        let metadata: [Int: AO3MetadataRecord] = [
            1: makeMetadata(fandoms: ["Fandom A"], relationships: ["Ship A/B"], chapterCurrent: 10, chapterTotal: 10),
            2: makeMetadata(fandoms: ["Fandom A"], relationships: [], chapterCurrent: 5, chapterTotal: 5),
            3: makeMetadata(fandoms: ["Fandom B"], relationships: [], chapterCurrent: 1, chapterTotal: 1)
        ]

        let groups = buildSeriesGroups(allEntries: entries, byID: byID, seriesMetadata: metadata)

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.values.first)
        XCTAssertEqual(group.works.count, 3)
        XCTAssertEqual(Set(group.allFandoms), Set(["Fandom A", "Fandom B"]))
        XCTAssertEqual(Set(group.allRelationships), Set(["Ship A/B"]))
    }

    // MARK: - Solo work excluded entirely

    func testSoloWorkAfterFilteringExcludesSeriesEntirely() {
        let works = [makeBook(id: 1, tags: [])]
        let entries = [makeEntry(calibreID: 1, seriesIndex: 1)]
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })

        let groups = buildSeriesGroups(allEntries: entries, byID: byID, seriesMetadata: [:])

        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Anthology-flagged work excluded, doesn't disqualify the rest

    func testAnthologyFlaggedWorkExcludedButDoesNotDisqualifyRestOfSeries() throws {
        let anthologyComment = "Anthology containing:\nWork One\nWork Two"
        let works = [
            makeBook(id: 1, tags: []),
            makeBook(id: 2, tags: []),
            makeBook(id: 3, tags: [], comment: anthologyComment)
        ]
        let entries = [
            makeEntry(calibreID: 1, seriesIndex: 1),
            makeEntry(calibreID: 2, seriesIndex: 2),
            makeEntry(calibreID: 3, seriesIndex: 3)
        ]
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })

        let groups = buildSeriesGroups(allEntries: entries, byID: byID, seriesMetadata: [:])

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.values.first)
        // The series still forms (2 non-anthology works > 1), and the
        // anthology work itself is excluded from `works`.
        XCTAssertEqual(group.works.map(\.id).sorted(), [1, 2])
    }

    // MARK: - duplicateLoserIDs entry excluded at the entriesBySeries grouping step

    func testDuplicateLoserExcludedAtGroupingStep() throws {
        let works = [
            makeBook(id: 1, tags: []),
            makeBook(id: 2, tags: []),
            makeBook(id: 3, tags: []) // will be marked as a duplicate loser
        ]
        let entries = [
            makeEntry(calibreID: 1, seriesIndex: 1),
            makeEntry(calibreID: 2, seriesIndex: 2),
            makeEntry(calibreID: 3, seriesIndex: 3)
        ]
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })

        let groups = buildSeriesGroups(
            allEntries: entries,
            byID: byID,
            seriesMetadata: [:],
            duplicateLoserIDs: [3]
        )

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.values.first)
        XCTAssertEqual(group.works.map(\.id).sorted(), [1, 2])
    }

    // MARK: - missingIndices / workIndices propagation for a gap

    func testMissingIndicesPropagatesForSeriesWithGap() throws {
        let works = [
            makeBook(id: 1, tags: []),
            makeBook(id: 2, tags: []),
            makeBook(id: 3, tags: [])
        ]
        // Parts 1, 2, 4 present -- 3 missing.
        let entries = [
            makeEntry(calibreID: 1, seriesIndex: 1),
            makeEntry(calibreID: 2, seriesIndex: 2),
            makeEntry(calibreID: 3, seriesIndex: 4)
        ]
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })

        let groups = buildSeriesGroups(allEntries: entries, byID: byID, seriesMetadata: [:])

        let group = try XCTUnwrap(groups.values.first)
        XCTAssertEqual(group.workIndices.sorted(), [1, 2, 4])
        XCTAssertEqual(group.missingIndices, [3])
    }

    // MARK: - chapterTotalTotal / hasUnknownChapterTotal

    func testChapterTotalsPopulatedWhenEveryWorkHasKnownChapterTotal() throws {
        let works = [makeBook(id: 1, tags: []), makeBook(id: 2, tags: [])]
        let entries = [makeEntry(calibreID: 1, seriesIndex: 1), makeEntry(calibreID: 2, seriesIndex: 2)]
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        let metadata: [Int: AO3MetadataRecord] = [
            1: makeMetadata(chapterCurrent: 10, chapterTotal: 10),
            2: makeMetadata(chapterCurrent: 5, chapterTotal: 5)
        ]

        let groups = buildSeriesGroups(allEntries: entries, byID: byID, seriesMetadata: metadata)

        let group = try XCTUnwrap(groups.values.first)
        XCTAssertEqual(group.chapterTotalTotal, 15)
        XCTAssertFalse(group.hasUnknownChapterTotal)
    }

    func testChapterTotalsUnknownWhenAtLeastOneWorkLacksChapterTotal() throws {
        let works = [makeBook(id: 1, tags: []), makeBook(id: 2, tags: [])]
        let entries = [makeEntry(calibreID: 1, seriesIndex: 1), makeEntry(calibreID: 2, seriesIndex: 2)]
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        let metadata: [Int: AO3MetadataRecord] = [
            1: makeMetadata(chapterCurrent: 10, chapterTotal: 10),
            2: makeMetadata(chapterCurrent: 5, chapterTotal: nil) // in-progress work, total unknown
        ]

        let groups = buildSeriesGroups(allEntries: entries, byID: byID, seriesMetadata: metadata)

        let group = try XCTUnwrap(groups.values.first)
        XCTAssertNil(group.chapterTotalTotal)
        XCTAssertTrue(group.hasUnknownChapterTotal)
    }

    // MARK: - Fixtures

    private func makeEntry(calibreID: Int, seriesIndex: Int) -> SeriesCacheEntry {
        SeriesCacheEntry(
            calibreID: calibreID,
            seriesName: "Test Series",
            seriesIndex: seriesIndex,
            ao3SeriesID: "12345",
            isAnthology: false,
            calibreSeriesID: nil
        )
    }

    private func makeBook(id: Int, tags: [String], comment: String? = nil) -> CalibreBook {
        var book = CalibreBook(
            id: id,
            title: "Book \(id)",
            series: "Test Series",
            seriesIndex: Double(id),
            wordCount: 1000,
            kudos: nil,
            publishedDate: nil,
            publisher: nil,
            relativePath: "path/\(id).epub"
        )
        book.tags = tags
        book.comment = comment
        return book
    }

    private func makeMetadata(
        fandoms: [String] = [],
        relationships: [String] = [],
        chapterCurrent: Int? = nil,
        chapterTotal: Int? = nil
    ) -> AO3MetadataRecord {
        AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: chapterCurrent,
            chapterTotal: chapterTotal,
            isComplete: chapterCurrent != nil && chapterCurrent == chapterTotal,
            language: nil,
            publishedDate: nil,
            updatedDate: nil,
            fandoms: fandoms,
            relationships: relationships,
            characters: [],
            additionalTags: [],
            categories: [],
            ao3Collections: [],
            series: [],
            rating: nil,
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )
    }
}
