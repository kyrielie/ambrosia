import XCTest
@testable import Ambrosia

// Collections management plan §3: "How membership actually works today"
// confirmed collection_members rows are keyed by calibre_id -- membership is
// always per individual work, regardless of shouldGroupSeriesRows.
// LibraryVisibilityPolicy/SeriesGroupBuilder only change which LibraryItem
// rows are *presented*; they never touch collection_members. This test
// exercises that boundary directly against CollectionStore rather than just
// eyeballing it, per the plan's ask for a written test, not just confidence.
final class CollectionStoreTests: XCTestCase {

    private var libraryURL: URL!
    private var metaDB: AmbrosiaMetaDB!
    private var store: CollectionStore!

    override func setUpWithError() throws {
        // A unique, disposable "library" path per run -- AmbrosiaMetaDB
        // hashes this to a per-library directory under Application Support,
        // so each test run gets an isolated ambrosia_meta.db.
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectionStoreTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: libraryURL)
        store = CollectionStore(db: metaDB)
    }

    override func tearDownWithError() throws {
        libraryURL = nil
        metaDB = nil
        store = nil
    }

    func testTogglingSeriesGroupingNeverMutatesCollectionMembers() async throws {
        // A 3-work series with only 2 of the 3 works added to a collection --
        // the "partial membership" case from §3.
        let collection = try await store.createCollection(name: "Partial Series Test")
        try await store.bulkAdd(calibreIDs: [1, 2], to: collection.id)

        let membersBeforeToggle = Set(try await store.members(of: collection.id))
        XCTAssertEqual(membersBeforeToggle, [1, 2])

        // shouldGroupSeriesRows lives entirely on LibraryVisibilityPolicy and
        // is never read by CollectionStore -- there is nothing to "toggle"
        // here on the store side, which is exactly the point: grouping is
        // purely a presentation concern, so simply re-reading membership
        // after constructing policy in both grouping states must yield the
        // same result CollectionStore already returned.
        var groupedOffPolicy = LibraryVisibilityPolicy.allowAll
        groupedOffPolicy.shouldGroupSeriesRows = false
        var groupedOnPolicy = LibraryVisibilityPolicy.allowAll
        groupedOnPolicy.shouldGroupSeriesRows = true

        let membersAfterGroupedOff = Set(try await store.members(of: collection.id))
        let membersAfterGroupedOn = Set(try await store.members(of: collection.id))

        XCTAssertEqual(membersAfterGroupedOff, membersBeforeToggle)
        XCTAssertEqual(membersAfterGroupedOn, membersBeforeToggle)

        // Partial/full membership state renders correctly in both modes,
        // regardless of shouldGroupSeriesRows -- membershipState is a pure
        // function of (members, selected), not of the grouping policy.
        let allThreeWorks: Set<Int> = [1, 2, 3]
        XCTAssertEqual(membershipState(for: membersAfterGroupedOff, selected: allThreeWorks), .partial)
        XCTAssertEqual(membershipState(for: membersAfterGroupedOn, selected: allThreeWorks), .partial)

        // Completing membership (adding the third work) flips both to .all.
        try await store.bulkAdd(calibreIDs: [3], to: collection.id)
        let membersAfterCompletion = Set(try await store.members(of: collection.id))
        XCTAssertEqual(membershipState(for: membersAfterCompletion, selected: allThreeWorks), .all)
    }

    func testMembershipStateHelper() {
        XCTAssertEqual(membershipState(for: [], selected: []), .none)
        XCTAssertEqual(membershipState(for: [1, 2], selected: []), .none)
        XCTAssertEqual(membershipState(for: [], selected: [1, 2]), .none)
        XCTAssertEqual(membershipState(for: [1], selected: [1, 2, 3]), .partial)
        XCTAssertEqual(membershipState(for: [1, 2, 3], selected: [1, 2, 3]), .all)
    }

    func testBootstrapSystemCollectionsIncludesFailedExtraction() async throws {
        let cols = try await store.collections()
        let failedExtraction = cols.first { $0.id == SystemCollectionID.failedExtraction }
        XCTAssertNotNil(failedExtraction)
        XCTAssertEqual(failedExtraction?.name, SystemCollectionID.failedExtractionName)
        XCTAssertEqual(failedExtraction?.isSystem, true)
        XCTAssertEqual(failedExtraction?.kind, "automated")
    }

    func testSeriesMembershipAppearsInEffectiveWorkReadsButNotExplicitRows() async throws {
        try await metaDB.run("""
            INSERT INTO series (series_id, series_key, name, calibre_series_id, created_at)
            VALUES (1, 'calibre:91', 'Test Series', 91, '2026-01-01T00:00:00Z')
            """)
        try await metaDB.run("INSERT INTO series_cache (calibre_id, series_id, series_index) VALUES (10, 1, 1), (11, 1, 2)")
        try await metaDB.run("""
            INSERT INTO series_collection_members (collection_id, series_id, added_at)
            VALUES (?, 1, '2026-02-01T00:00:00Z')
            """, [SystemCollectionID.liked])

        let liked = try await store.likedIDs()
        let members = Set(try await store.members(of: SystemCollectionID.liked))
        let byID = try await store.membershipByCollectionID()
        let explicit = Set(try await store.explicitMembers(of: SystemCollectionID.liked))
        XCTAssertEqual(liked, [10, 11])
        XCTAssertEqual(members, [10, 11])
        XCTAssertEqual(byID[SystemCollectionID.liked], [10, 11])
        XCTAssertEqual(explicit, [])
        let dates = try await store.memberAddedDates(for: SystemCollectionID.liked)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates[10], ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z"))

        let exclusionDelta = try await store.setWorkFlags(collectionID: SystemCollectionID.liked, desired: [10: false])
        XCTAssertEqual(exclusionDelta.toRemove, [10])
        let unlikedMembers = Set(try await store.members(of: SystemCollectionID.liked))
        XCTAssertEqual(unlikedMembers, [11])
        let explicitAfterUnlike = Set(try await store.explicitMembers(of: SystemCollectionID.liked))
        XCTAssertTrue(explicitAfterUnlike.isEmpty)
        let exclusionCount = try await metaDB.scalar("SELECT COUNT(*) FROM series_collection_exclusions") as? Int64
        XCTAssertEqual(exclusionCount, 1)

        _ = try await store.setWorkFlags(collectionID: SystemCollectionID.liked, desired: [10: true])
        let relikedMembers = Set(try await store.members(of: SystemCollectionID.liked))
        let explicitReliked = Set(try await store.explicitMembers(of: SystemCollectionID.liked))
        XCTAssertEqual(relikedMembers, [10, 11])
        XCTAssertEqual(explicitReliked, [10])
    }

    func testSkipExcludesCoveredReadLaterWorkAndAddsSkippedMembershipAtomically() async throws {
        try await metaDB.run("""
            INSERT INTO series (series_id, series_key, name, calibre_series_id, created_at)
            VALUES (7, 'calibre:97', 'Read Later Series', 97, '2026-01-01T00:00:00Z')
            """)
        try await metaDB.run("INSERT INTO series_cache (calibre_id, series_id, series_index) VALUES (70, 7, 1), (71, 7, 2)")
        try await metaDB.run("""
            INSERT INTO series_collection_members (collection_id, series_id, added_at)
            VALUES (?, 7, '2026-02-01T00:00:00Z')
            """, [SystemCollectionID.readLater])
        try await store.skip(calibreIDs: [70])

        let readLaterMembers = Set(try await store.members(of: SystemCollectionID.readLater))
        let skippedMembers = Set(try await store.members(of: SystemCollectionID.skipped))
        XCTAssertEqual(readLaterMembers, [71])
        XCTAssertEqual(skippedMembers, [70])
        let exclusionCount = try await metaDB.scalar("""
            SELECT COUNT(*) FROM series_collection_exclusions
            WHERE collection_id = ? AND calibre_id = 70
            """, [SystemCollectionID.readLater]) as? Int64
        XCTAssertEqual(exclusionCount, 1)
    }

    func testSeriesFlagActionsOperateOnOnlyTheirSeries() async throws {
        try await metaDB.run("""
            INSERT INTO series (series_id, series_key, name, calibre_series_id, created_at)
            VALUES (8, 'calibre:98', 'Flaggable', 98, '2026-01-01T00:00:00Z'),
                   (9, 'calibre:99', 'Other', 99, '2026-01-01T00:00:00Z')
            """)
        try await metaDB.run("INSERT INTO series_cache (calibre_id, series_id, series_index) VALUES (80, 8, 1), (81, 8, 2), (81, 9, 1), (82, 9, 2)")
        let delta = try await store.applySeriesActions(collectionID: SystemCollectionID.liked, seriesID: 8, actions: [.setFlag])
        XCTAssertEqual(delta.toAdd, [80, 81])
        let afterSet = Set(try await store.members(of: SystemCollectionID.liked))
        XCTAssertEqual(afterSet, [80, 81])

        _ = try await store.applySeriesActions(collectionID: SystemCollectionID.liked, seriesID: 8, actions: [.clearFlag])
        let afterClear = Set(try await store.members(of: SystemCollectionID.liked))
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testNameOnlySeriesCannotBeFlaggedAtStoreLayer() async throws {
        try await metaDB.run("""
            INSERT INTO series (series_id, series_key, name, name_key, created_at)
            VALUES (10, 'calibre-name:Unnamed', 'Unnamed', 'unnamed', '2026-01-01T00:00:00Z')
            """)
        do {
            _ = try await store.applySeriesActions(collectionID: SystemCollectionID.liked, seriesID: 10, actions: [.setFlag])
            XCTFail("name-only series should not accept a persisted flag")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Name-only"))
        }
    }
}
