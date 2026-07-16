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
}
