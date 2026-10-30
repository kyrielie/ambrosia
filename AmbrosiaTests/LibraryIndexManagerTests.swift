import SQLite
import XCTest
@testable import Ambrosia

/// Coverage for `LibraryIndexManager` (`Ambrosia/Database/LibraryIndexManager.swift`).
///
/// `.shared` writes to the real Application Support path and (via `relink`)
/// moves real library directories on disk, so these tests never touch
/// `.shared` — they use `LibraryIndexManager.makeForTesting(directory:)`,
/// which scopes every read/write to a unique temp directory per test. That
/// override seam is a real source change (added specifically to make this
/// file testable), not something inferred from existing behavior.
final class LibraryIndexManagerTests: XCTestCase {

    private var tempDir: URL!
    private var manager: LibraryIndexManager!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = LibraryIndexManager.makeForTesting(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        manager = nil
    }

    private func makeLibraryURL(_ name: String) -> URL {
        tempDir.appendingPathComponent(name)
    }

    // MARK: - entries() on an empty/missing index

    func testEntriesOnFreshDirectoryReturnsEmpty() {
        XCTAssertEqual(manager.entries(), [])
    }

    // MARK: - record(url:)

    func testRecordAddsNewEntry() {
        let libURL = makeLibraryURL("LibraryA")
        manager.record(url: libURL)

        let entries = manager.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.displayName, "LibraryA")
        XCTAssertEqual(entries.first?.hash, libraryHash(for: libURL))
    }

    func testRecordingSameURLTwiceUpsertsToOneEntry() {
        let libURL = makeLibraryURL("LibraryA")
        manager.record(url: libURL)
        let firstOpened = manager.entries().first?.lastOpened

        // Record again -- must update the existing entry (by hash), not
        // append a duplicate.
        manager.record(url: libURL)
        let entries = manager.entries()

        XCTAssertEqual(entries.count, 1, "recording the same URL twice must upsert, not duplicate")
        XCTAssertNotNil(firstOpened)
        XCTAssertNotNil(entries.first?.lastOpened)
    }

    func testRecordingDifferentURLsAddsSeparateEntries() {
        manager.record(url: makeLibraryURL("LibraryA"))
        manager.record(url: makeLibraryURL("LibraryB"))

        XCTAssertEqual(manager.entries().count, 2)
    }

    // MARK: - update(oldHash:newHash:newURL:)

    func testUpdateRemovesBothOldAndNewHashEntriesBeforeAppending() {
        let oldURL = makeLibraryURL("LibraryOld")
        let newURL = makeLibraryURL("LibraryNew")
        let oldHash = libraryHash(for: oldURL)
        let newHash = libraryHash(for: newURL)

        // Seed both an old-hash entry and a pre-existing new-hash entry, so
        // the removeAll { $0.hash == oldHash || $0.hash == newHash } dedup
        // logic (line 51 in the source) has both to remove before the fresh
        // entry is appended.
        manager.record(url: oldURL)
        manager.record(url: newURL)
        XCTAssertEqual(manager.entries().count, 2)

        manager.update(oldHash: oldHash, newHash: newHash, newURL: newURL)

        let entries = manager.entries()
        XCTAssertEqual(entries.count, 1, "old-hash and pre-existing new-hash entries must both be removed")
        XCTAssertEqual(entries.first?.hash, newHash)
        XCTAssertEqual(entries.first?.displayName, "LibraryNew")
    }

    func testUpdateWithNoPriorNewHashEntryStillAppendsExactlyOne() {
        let oldURL = makeLibraryURL("LibraryOld")
        let newURL = makeLibraryURL("LibraryNew")
        manager.record(url: oldURL)

        manager.update(oldHash: libraryHash(for: oldURL), newHash: libraryHash(for: newURL), newURL: newURL)

        let entries = manager.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.hash, libraryHash(for: newURL))
    }

    // MARK: - entries() sort order

    func testEntriesAreSortedByLastOpenedDescending() throws {
        // entries() just decodes whatever is on disk -- it does not sort.
        // The sort happens in the private write() function, which only
        // runs as a side effect of record()/update(). So this test seeds
        // the index file directly with entries in a deliberately *unsorted*
        // order and distinct, controlled timestamps (avoiding any reliance
        // on record()'s real "now" stamping, which is only second-precision
        // and risks ties across rapid calls), then calls record() once more
        // to trigger a real write() and asserts the result -- read fresh
        // from disk -- is correctly sorted.
        let seeded = [
            LibraryIndexEntry(hash: "aaa", lastKnownPath: "/a", displayName: "Oldest", lastOpened: "2026-01-01T00:00:00Z"),
            LibraryIndexEntry(hash: "ccc", lastKnownPath: "/c", displayName: "Newest", lastOpened: "2026-08-01T00:00:00Z"),
            LibraryIndexEntry(hash: "bbb", lastKnownPath: "/b", displayName: "Middle", lastOpened: "2026-06-01T00:00:00Z")
        ]
        let data = try JSONEncoder().encode(seeded)
        try data.write(to: tempDir.appendingPathComponent("index.json"))

        // record() reads the seeded (unsorted) entries via entries(),
        // appends a new one stamped with the real current time (necessarily
        // the most recent of all four), and writes -- exercising the sort.
        manager.record(url: makeLibraryURL("JustNow"))

        let names = manager.entries().map(\.displayName)
        XCTAssertEqual(names, ["JustNow", "Newest", "Middle", "Oldest"],
                        "entries() must reflect write()'s descending-by-lastOpened sort")
    }

    // MARK: - relink(oldHash:newLibraryURL:)

    func testRelinkMovesDirectoryAndUpdatesEntry() throws {
        let oldURL = makeLibraryURL("LibraryOld")
        let newURL = makeLibraryURL("LibraryNew")
        let oldHash = libraryHash(for: oldURL)
        let newHash = libraryHash(for: newURL)

        manager.record(url: oldURL)

        // relink moves <base>/<oldHash> -> <base>/<newHash> on disk, so that
        // directory must exist under the override directory first.
        let base = try XCTUnwrap(tempDir)
        let oldDir = base.appendingPathComponent(oldHash)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let marker = oldDir.appendingPathComponent("marker.txt")
        try "hello".write(to: marker, atomically: true, encoding: .utf8)

        try manager.relink(oldHash: oldHash, newLibraryURL: newURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path), "old per-library directory must be moved away")
        let newDir = base.appendingPathComponent(newHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("marker.txt").path),
                      "contents must be preserved across the move")

        let entries = manager.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.hash, newHash)
        XCTAssertEqual(entries.first?.displayName, "LibraryNew")
    }

    func testRelinkOverwritesExistingDestinationDirectory() throws {
        let oldURL = makeLibraryURL("LibraryOld")
        let newURL = makeLibraryURL("LibraryNew")
        let oldHash = libraryHash(for: oldURL)
        let newHash = libraryHash(for: newURL)

        let base = try XCTUnwrap(tempDir)
        let oldDir = base.appendingPathComponent(oldHash)
        let newDir = base.appendingPathComponent(newHash)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try "stale".write(to: newDir.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)

        manager.record(url: oldURL)

        try manager.relink(oldHash: oldHash, newLibraryURL: newURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("stale.txt").path),
                        "a pre-existing destination directory must be replaced, not merged into")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path))
    }

    // MARK: - remove(hash:deleteAppSupportMetadata:)

    func testRemoveRemovesEntryFromIndex() {
        let libURL1 = makeLibraryURL("Library1")
        let libURL2 = makeLibraryURL("Library2")
        manager.record(url: libURL1)
        manager.record(url: libURL2)

        XCTAssertEqual(manager.entries().count, 2)
        let hash1 = libraryHash(for: libURL1)
        manager.remove(hash: hash1, deleteAppSupportMetadata: false)

        let remaining = manager.entries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.displayName, "Library2")
    }

    func testRemoveDeletesMetadataDirectoryWhenRequested() throws {
        let libURL = makeLibraryURL("LibraryWithMeta")
        let hash = libraryHash(for: libURL)
        manager.record(url: libURL)

        let metaDir = tempDir.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let file = metaDir.appendingPathComponent("ambrosia_meta.db")
        try "dummy".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        manager.remove(hash: hash, deleteAppSupportMetadata: true)

        XCTAssertEqual(manager.entries().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaDir.path))
    }

    // MARK: - Bookmarks & Calibre UUID

    func testRecordStoresBookmarkData() {
        let libURL = makeLibraryURL("LibraryBookmarkTest")
        try? FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)

        manager.record(url: libURL)
        let entries = manager.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries.first?.bookmarkData)
    }

    func testResolveURLWithValidBookmark() throws {
        let libURL = makeLibraryURL("LibraryResolveTest")
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)
        let dbURL = libURL.appendingPathComponent("metadata.db")
        try Data("mock".utf8).write(to: dbURL)

        manager.record(url: libURL)
        let entry = try XCTUnwrap(manager.entries().first)

        let resolved = manager.resolveURL(for: entry)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.standardizedFileURL, libURL.standardizedFileURL)
    }

    func testResolveURLWhenMoved() throws {
        let libURL = makeLibraryURL("LibraryMoveInitial")
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)
        let dbURL = libURL.appendingPathComponent("metadata.db")
        try Data("mock".utf8).write(to: dbURL)

        manager.record(url: libURL)
        let entry = try XCTUnwrap(manager.entries().first)

        let movedURL = makeLibraryURL("LibraryMoveDestination")
        try FileManager.default.moveItem(at: libURL, to: movedURL)

        let resolved = manager.resolveURL(for: entry)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.standardizedFileURL, movedURL.standardizedFileURL)
    }

    func testRecordExtractsCalibreUUID() throws {
        let libURL = makeLibraryURL("LibraryUUIDTest")
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)
        let dbURL = libURL.appendingPathComponent("metadata.db")
        let db = try Connection(dbURL.path)
        try db.run("CREATE TABLE library_id (id INTEGER PRIMARY KEY, uuid TEXT NOT NULL);")
        try db.run("INSERT INTO library_id (uuid) VALUES ('test-uuid-12345');")

        manager.record(url: libURL)
        let entry = try XCTUnwrap(manager.entries().first)
        XCTAssertEqual(entry.calibreUUID, "test-uuid-12345")
    }

    func testResolveMissingLibraryWithUUID() throws {
        let searchDir = tempDir.appendingPathComponent("SearchDir")
        let targetLib = searchDir.appendingPathComponent("FoundLibrary")
        try FileManager.default.createDirectory(at: targetLib, withIntermediateDirectories: true)
        let dbURL = targetLib.appendingPathComponent("metadata.db")
        let db = try Connection(dbURL.path)
        try db.run("CREATE TABLE library_id (id INTEGER PRIMARY KEY, uuid TEXT NOT NULL);")
        try db.run("INSERT INTO library_id (uuid) VALUES ('target-uuid-999');")

        let found = manager.findLibrary(withUUID: "target-uuid-999", inSearchDirectories: [searchDir])
        XCTAssertEqual(found?.standardizedFileURL, targetLib.standardizedFileURL)
    }
}
