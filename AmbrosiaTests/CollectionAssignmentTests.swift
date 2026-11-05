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
        session = nil
        if let libraryRoot {
            try? FileManager.default.removeItem(at: libraryRoot)
        }
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
}
