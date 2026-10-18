import XCTest
@testable import Ambrosia

/// Pure decision logic for the Series or Merged sync, plus the
/// `CollectionStore.applyMemberDelta` write path.
final class MembershipDeltaTests: XCTestCase {

    func testIdenticalSetsProduceEmptyDelta() {
        let delta = MembershipDelta(current: [1, 2, 3], computed: [3, 2, 1])
        XCTAssertTrue(delta.isEmpty)
        XCTAssertEqual(delta.toAdd, [])
        XCTAssertEqual(delta.toRemove, [])
    }

    func testBothEmptyIsEmptyDelta() {
        XCTAssertTrue(MembershipDelta(current: [], computed: []).isEmpty)
    }

    func testAddedAndRemovedAreSortedAndDisjoint() {
        let delta = MembershipDelta(current: [5, 1, 9], computed: [9, 7, 3])
        XCTAssertEqual(delta.toAdd, [3, 7])
        XCTAssertEqual(delta.toRemove, [1, 5])
        XCTAssertFalse(delta.isEmpty)
    }

    func testFirstSyncFromEmptyAddsEverything() {
        let delta = MembershipDelta(current: [], computed: [2, 1])
        XCTAssertEqual(delta.toAdd, [1, 2])
        XCTAssertEqual(delta.toRemove, [])
    }

    func testEverythingRemoved() {
        let delta = MembershipDelta(current: [4, 2], computed: [])
        XCTAssertEqual(delta.toAdd, [])
        XCTAssertEqual(delta.toRemove, [2, 4])
    }
}

final class CollectionStoreDeltaTests: XCTestCase {

    private var libraryURL: URL!
    private var metaDB: AmbrosiaMetaDB!
    private var store: CollectionStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectionStoreDeltaTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: libraryURL)
        store = CollectionStore(db: metaDB)
    }

    override func tearDownWithError() throws {
        libraryURL = nil
        metaDB = nil
        store = nil
    }

    func testApplyDeltaAddsAndRemovesOnlyTheDifference() async throws {
        let collection = try await store.createCollection(name: "Delta Test")
        try await store.bulkAdd(calibreIDs: [1, 2, 3], to: collection.id)

        try await store.applyMemberDelta(of: collection.id, adding: [4, 5], removing: [1])

        let members = Set(try await store.members(of: collection.id))
        XCTAssertEqual(members, [2, 3, 4, 5])
    }

    func testEmptyDeltaLeavesMembersUntouched() async throws {
        let collection = try await store.createCollection(name: "Empty Delta Test")
        try await store.bulkAdd(calibreIDs: [7, 8], to: collection.id)

        try await store.applyMemberDelta(of: collection.id, adding: [], removing: [])

        let members = Set(try await store.members(of: collection.id))
        XCTAssertEqual(members, [7, 8])
    }

    func testAddingAnExistingMemberIsIdempotent() async throws {
        let collection = try await store.createCollection(name: "Idempotent Delta Test")
        try await store.bulkAdd(calibreIDs: [1], to: collection.id)

        try await store.applyMemberDelta(of: collection.id, adding: [1, 2], removing: [])

        let members = try await store.members(of: collection.id)
        XCTAssertEqual(members.sorted(), [1, 2])
    }

    func testDeltaResultMatchesReplaceMembers() async throws {
        let viaDelta = try await store.createCollection(name: "Via Delta")
        let viaReplace = try await store.createCollection(name: "Via Replace")
        try await store.bulkAdd(calibreIDs: [1, 2, 3, 4], to: viaDelta.id)
        let target: Set<Int> = [3, 4, 5, 6]

        let delta = MembershipDelta(current: [1, 2, 3, 4], computed: target)
        try await store.applyMemberDelta(of: viaDelta.id, adding: delta.toAdd, removing: delta.toRemove)
        try await store.replaceMembers(of: viaReplace.id, with: target)

        let deltaMembers = Set(try await store.members(of: viaDelta.id))
        let replaceMembers = Set(try await store.members(of: viaReplace.id))
        XCTAssertEqual(deltaMembers, target)
        XCTAssertEqual(replaceMembers, target)
    }
}
