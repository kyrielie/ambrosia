import XCTest
@testable import Ambrosia

@MainActor
final class CollectionAssignmentTests: XCTestCase {

    private var libraryRoot: URL!
    private var session: LibrarySession!

    override func setUp() async throws {
        libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
        session = LibrarySession()
        await session.open(url: libraryRoot)
    }

    override func tearDown() async throws {
        session?.close()
        session = nil
        libraryRoot = nil
    }

    func testRapidTogglingReadLaterLeavesConsistentFinalState() async throws {
        guard let store = session.collectionStore else {
            XCTFail("CollectionStore was nil")
            return
        }

        let bookID = 1

        // Rapid click 1: add to Read Later
        CollectionAssignment.toggleReadLater(calibreIDs: [bookID], session: session)
        XCTAssertTrue(session.cachedReadLaterIDs.contains(bookID))

        // Rapid click 2: remove from Read Later
        CollectionAssignment.toggleReadLater(calibreIDs: [bookID], session: session)
        XCTAssertFalse(session.cachedReadLaterIDs.contains(bookID))

        // Rapid click 3: add to Read Later
        CollectionAssignment.toggleReadLater(calibreIDs: [bookID], session: session)
        XCTAssertTrue(session.cachedReadLaterIDs.contains(bookID))

        // Wait for debouncer (200ms) to settle and write to store
        try await Task.sleep(nanoseconds: 350_000_000)

        let members = try await store.members(of: SystemCollectionID.readLater)
        XCTAssertTrue(members.contains(bookID))
        XCTAssertTrue(session.cachedReadLaterIDs.contains(bookID))

        // Rapid toggle off (off, on, off)
        CollectionAssignment.toggleReadLater(calibreIDs: [bookID], session: session)
        XCTAssertFalse(session.cachedReadLaterIDs.contains(bookID))

        CollectionAssignment.toggleReadLater(calibreIDs: [bookID], session: session)
        XCTAssertTrue(session.cachedReadLaterIDs.contains(bookID))

        CollectionAssignment.toggleReadLater(calibreIDs: [bookID], session: session)
        XCTAssertFalse(session.cachedReadLaterIDs.contains(bookID))

        try await Task.sleep(nanoseconds: 350_000_000)

        let membersAfter = try await store.members(of: SystemCollectionID.readLater)
        XCTAssertFalse(membersAfter.contains(bookID))
        XCTAssertFalse(session.cachedReadLaterIDs.contains(bookID))
    }

    func testCompletedBooksCountUnitesThreeSourcesAndDeduplicates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletedBooksCountTest-\(UUID().uuidString)")
        let metaDB = try AmbrosiaMetaDB(libraryURL: tempDir)
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now

        // 1. Work 101 recorded via reading_history session
        let s1 = try await metaDB.startReadingSession(
            calibreID: 101,
            percentStart: 0.0,
            startedAt: start.addingTimeInterval(3600)
        )
        try await metaDB.updateReadingSession(
            id: s1,
            calibreID: 101,
            percentEnd: 1.0,
            endedAt: start.addingTimeInterval(7200)
        )

        // 2. Work 102 marked as Finished (collection membership)
        let store = CollectionStore(db: metaDB)
        try await store.bulkAdd(calibreIDs: [102], to: SystemCollectionID.finished)

        // 3. Work 103 recorded via book_state (e.g. quick Mark as Read)
        try await metaDB.markBookRead(calibreID: 103)

        // 4. Work 101 ALSO recorded in book_state (should deduplicate)
        try await metaDB.markBookRead(calibreID: 101)

        // Verify completedBooksCount counts 3 distinct works
        let count = try await metaDB.completedBooksCount(start: start, end: end)
        XCTAssertEqual(count, 3)
    }

    func testReadingStatsInsightsComputesFandomsShipsAndTropes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingStatsInsightsTest-\(UUID().uuidString)")
        let metaDB = try AmbrosiaMetaDB(libraryURL: tempDir)
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now

        // Insert metadata for book 201: Romantic ship + Fandom A + Tropes
        let record201 = AO3MetadataRecord(
            storyURL: nil,
            workID: "201",
            authors: [AO3AuthorEntry(username: "AuthorA", pseud: nil, profileURL: nil, source: .byline)],
            kudosCount: 50,
            wordCount: 10000,
            chapterCurrent: 5,
            chapterTotal: 5,
            isComplete: true,
            language: "en",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Harry Potter"],
            relationships: ["Harry Potter/Draco Malfoy"],
            characters: [],
            additionalTags: ["Slow Burn", "Enemies to Lovers"],
            categories: [],
            ao3Collections: [],
            series: [],
            rating: "Explicit",
            warnings: [],
            extractedAt: "2026-11-05T00:00:00Z"
        )
        try await metaDB.insert(record201, calibreID: 201)

        // Insert metadata for book 202: Platonic friendship + Fandom B + Tropes
        let record202 = AO3MetadataRecord(
            storyURL: nil,
            workID: "202",
            authors: [AO3AuthorEntry(username: "AuthorB", pseud: nil, profileURL: nil, source: .byline)],
            kudosCount: 30,
            wordCount: 6000,
            chapterCurrent: 3,
            chapterTotal: 3,
            isComplete: true,
            language: "en",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Sherlock"],
            relationships: ["Sherlock Holmes & John Watson"],
            characters: [],
            additionalTags: ["Case Fic", "Slow Burn"],
            categories: [],
            ao3Collections: [],
            series: [],
            rating: "Teen And Up Audiences",
            warnings: [],
            extractedAt: "2026-11-05T00:00:00Z"
        )
        try await metaDB.insert(record202, calibreID: 202)

        // Record reading sessions for 201 and 202
        let s201 = try await metaDB.startReadingSession(
            calibreID: 201,
            percentStart: 0.0,
            startedAt: now.addingTimeInterval(-3600)
        )
        try await metaDB.updateReadingSession(
            id: s201,
            calibreID: 201,
            percentEnd: 1.0,
            endedAt: now
        )

        let s202 = try await metaDB.startReadingSession(
            calibreID: 202,
            percentStart: 0.0,
            startedAt: now.addingTimeInterval(-7200)
        )
        try await metaDB.updateReadingSession(
            id: s202,
            calibreID: 202,
            percentEnd: 1.0,
            endedAt: now.addingTimeInterval(-3600)
        )

        let insights = try await metaDB.readingStatsInsights(start: start, end: end)
        XCTAssertEqual(insights.totalWords, 16000)
        XCTAssertEqual(insights.totalWorks, 2)
        XCTAssertGreaterThan(insights.wordsPerHour, 0)

        // Fandoms
        XCTAssertEqual(insights.topFandoms.count, 2)
        XCTAssertEqual(insights.topFandoms.first?.name, "Harry Potter")
        XCTAssertEqual(insights.topFandoms.first?.words, 10000)

        // Relationships
        XCTAssertEqual(insights.topRelationships.count, 2)
        let romantic = insights.topRelationships.first { $0.name == "Harry Potter/Draco Malfoy" }
        XCTAssertNotNil(romantic)
        XCTAssertTrue(romantic?.isRomantic ?? false)

        let platonic = insights.topRelationships.first { $0.name == "Sherlock Holmes & John Watson" }
        XCTAssertNotNil(platonic)
        XCTAssertFalse(platonic?.isRomantic ?? true)

        // Tropes
        let slowBurn = insights.topTags.first { $0.name == "Slow Burn" }
        XCTAssertNotNil(slowBurn)
        XCTAssertEqual(slowBurn?.works, 2)
    }

    func testSortFieldUnifiedCasesAndLegacyMapping() {
        let userCases = SortField.userFacingCases
        XCTAssertFalse(userCases.contains(.series))
        XCTAssertFalse(userCases.contains(.ao3Published))
        XCTAssertFalse(userCases.contains(.ao3Updated))
        XCTAssertTrue(userCases.contains(.published))
        XCTAssertTrue(userCases.contains(.updated))
        XCTAssertTrue(userCases.contains(.title))
        XCTAssertTrue(userCases.contains(.kudos))

        // LastViewState backward compatibility
        let stateSeries = LastViewState(sortField: .series, ascending: true, filterExpression: nil)
        XCTAssertEqual(stateSeries.sortField, .title)

        let stateAO3Pub = LastViewState(sortField: .ao3Published, ascending: true, filterExpression: nil)
        XCTAssertEqual(stateAO3Pub.sortField, .published)

        let stateAO3Upd = LastViewState(sortField: .ao3Updated, ascending: true, filterExpression: nil)
        XCTAssertEqual(stateAO3Upd.sortField, .updated)
    }
}
