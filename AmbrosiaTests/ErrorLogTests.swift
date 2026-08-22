import XCTest
@testable import Ambrosia

// Covers AmbrosiaMetaDB's error_log table -- see docs/metadb-and-migrations.md
// and docs/library-ui.md for the feature this backs (ErrorLogView, Export
// menu -> "Error Log..."). Follows CollectionStoreTests'
// setup convention: a real AmbrosiaMetaDB against a disposable temp-directory
// "library" path, exercised through the actor rather than mocked, since the
// actor boundary and the SQL are exactly what's under test here.
final class ErrorLogTests: XCTestCase {

    private var libraryURL: URL!
    private var metaDB: AmbrosiaMetaDB!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorLogTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: libraryURL)
    }

    override func tearDownWithError() throws {
        libraryURL = nil
        metaDB = nil
    }

    func testLogAndRetrieveError() async throws {
        try await metaDB.logError(
            subsystem: "EPUBParser",
            operation: "parse OPF",
            message: "missing spine element",
            calibreID: 42
        )

        let entries = try await metaDB.recentErrors()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].subsystem, "EPUBParser")
        XCTAssertEqual(entries[0].operation, "parse OPF")
        XCTAssertEqual(entries[0].message, "missing spine element")
        XCTAssertEqual(entries[0].calibreID, 42)
        // file/line default to the call site via #fileID/#line -- just
        // confirm they were captured as non-nil, not their exact values,
        // since asserting an exact line number would break on any edit
        // above this call in this same file.
        XCTAssertNotNil(entries[0].file)
        XCTAssertNotNil(entries[0].line)
    }

    func testCalibreIDIsOptional() async throws {
        // Library-wide failures (e.g. a LocalFeedServer route error) have no
        // associated book.
        try await metaDB.logError(
            subsystem: "LocalFeedServer",
            operation: "serve /feed.xml",
            message: "connection reset"
        )

        let entries = try await metaDB.recentErrors()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].calibreID)
    }

    func testRecentErrorsOrderedNewestFirst() async throws {
        try await metaDB.logError(subsystem: "A", operation: "op1", message: "first")
        try await metaDB.logError(subsystem: "B", operation: "op2", message: "second")
        try await metaDB.logError(subsystem: "C", operation: "op3", message: "third")

        let entries = try await metaDB.recentErrors()
        XCTAssertEqual(entries.map(\.message), ["third", "second", "first"])
    }

    func testRecentErrorsRespectsLimit() async throws {
        for i in 0..<5 {
            try await metaDB.logError(subsystem: "A", operation: "op", message: "error \(i)")
        }

        let entries = try await metaDB.recentErrors(limit: 3)
        XCTAssertEqual(entries.count, 3)
    }

    func testPruneErrorLogKeepsOnlyNewest() async throws {
        for i in 0..<10 {
            try await metaDB.logError(subsystem: "A", operation: "op", message: "error \(i)")
        }

        try await metaDB.pruneErrorLog(keeping: 4)

        let entries = try await metaDB.recentErrors(limit: 100)
        XCTAssertEqual(entries.count, 4)
        // The 4 newest ("error 9" down to "error 6") should survive.
        XCTAssertEqual(entries.map(\.message), ["error 9", "error 8", "error 7", "error 6"])
    }

    func testClearErrorLogRemovesAllRows() async throws {
        try await metaDB.logError(subsystem: "A", operation: "op", message: "one")
        try await metaDB.logError(subsystem: "B", operation: "op", message: "two")

        try await metaDB.clearErrorLog()

        let entries = try await metaDB.recentErrors()
        XCTAssertTrue(entries.isEmpty)
    }
}
