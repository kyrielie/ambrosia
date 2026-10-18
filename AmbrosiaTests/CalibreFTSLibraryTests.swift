// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SQLite
@testable import Ambrosia

final class CalibreFTSLibraryTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    // MARK: - Helpers

    private static let documents: [FTSTestFixture.Document] = [
        .init(id: 1, book: 10, format: "EPUB", text: "I sent my r\u{00E9}sum\u{00E9} yesterday"),
        .init(id: 2, book: 11, format: "EPUB", text: "I sent my resume yesterday"),
        .init(id: 3, book: 12, format: "EPUB", text: "The category of cats"),
        .init(id: 4, book: 14, format: "EPUB", text: "one two three four five"),
        .init(id: 5, book: 14, format: "PDF", text: "one is the loneliest number"),
        .init(id: 6, book: 15, format: "EPUB", text: "connection connected conn"),
        .init(id: 7, book: 16, format: "EPUB", text: "moose one"),
        .init(id: 8, book: 17, format: "EPUB", text: "I use C++ daily")
    ]

    private func makeRoot(_ docs: [FTSTestFixture.Document] = documents) throws -> URL {
        let root = try FTSTestFixture.makeLibraryRoot(books: docs)
        roots.append(root)
        return root
    }

    private func makeLibrary(_ docs: [FTSTestFixture.Document] = documents) throws -> (CalibreFTSLibrary, URL) {
        let root = try makeRoot(docs)
        let lib = try XCTUnwrap(CalibreFTSLibrary(libraryURL: root))
        return (lib, root)
    }

    private func ids(_ lib: CalibreFTSLibrary, _ text: String, formats: Set<String>? = nil) async throws -> [Int] {
        let query = try XCTUnwrap(FTSQuery.make(text, formats: formats))
        let token = lib.beginSearch()
        return try await lib.searchBooks(query, token: token).bookIDs.sorted()
    }

    private func ftsPath(_ root: URL) -> String {
        root.appendingPathComponent(FTSTestFixture.fileName).path
    }

    // MARK: - Mode selection

    func testRegisteredFixtureOpensNative() async throws {
        let (lib, _) = try makeLibrary()
        let mode = await lib.mode
        XCTAssertEqual(mode, .native)
    }

    func testMissingSearchableTextColumnYieldsNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia_fts_bad_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let conn = try Connection(ftsPath(root))
        try conn.execute("CREATE TABLE books_text (id INTEGER PRIMARY KEY, book INTEGER, format TEXT)")
        XCTAssertNil(CalibreFTSLibrary(libraryURL: root))
    }

    func testMissingFileYieldsNil() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia_fts_none_\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(CalibreFTSLibrary(libraryURL: root))
    }

    func testUnexpectedUserVersionFallsBackToLike() async throws {
        let root = try makeRoot()
        let writer = try Connection(ftsPath(root))
        try writer.execute("PRAGMA user_version = 2")
        let lib = try XCTUnwrap(CalibreFTSLibrary(libraryURL: root))
        let mode = await lib.mode
        XCTAssertEqual(mode, .likeFallback)
        // LIKE mode is a literal phrase scan.
        let found = try await ids(lib, "sent my resume")
        XCTAssertEqual(found, [11])
    }

    // MARK: - Phase 1

    func testOneIDPerBookWhenTwoFormatsMatch() async throws {
        let (lib, _) = try makeLibrary()
        let found = try await ids(lib, "one")
        XCTAssertEqual(found, [14, 16])   // book 14 has EPUB and PDF rows that both match
    }

    func testNoLimitAcrossFifteenHundredBooks() async throws {
        let docs = (1...1_500).map {
            FTSTestFixture.Document(id: $0, book: 1_000 + $0, format: "EPUB", text: "common word \($0)")
        }
        let (lib, _) = try makeLibrary(docs)
        let found = try await ids(lib, "common")
        XCTAssertEqual(found.count, 1_500)
    }

    func testFormatFilter() async throws {
        let (lib, _) = try makeLibrary()
        let epubOnly = try await ids(lib, "one", formats: ["EPUB"])
        XCTAssertEqual(epubOnly, [14, 16])
        let pdfOnly = try await ids(lib, "one", formats: ["pdf"])   // case-insensitive
        XCTAssertEqual(pdfOnly, [14])
        let none = try await ids(lib, "one", formats: [])
        XCTAssertEqual(none, [])
    }

    func testAccentSemantics() async throws {
        let (lib, _) = try makeLibrary()
        let plain = try await ids(lib, "resume")
        XCTAssertEqual(plain, [10, 11])
        let accented = try await ids(lib, "r\u{00E9}sum\u{00E9}")
        XCTAssertEqual(accented, [10])
    }

    func testRawFTS5OperatorsWork() async throws {
        let (lib, _) = try makeLibrary()
        let orResult = try await ids(lib, "moose OR category")
        XCTAssertEqual(orResult, [12, 16])
        let caret = try await ids(lib, "^one")
        XCTAssertEqual(caret, [14])   // only documents whose text begins with "one"
        let near = try await ids(lib, "NEAR(one four)")
        XCTAssertEqual(near, [14])
        let prefix = try await ids(lib, "conn*")
        XCTAssertEqual(prefix, [15])
    }

    func testBareMultiWordInputIsAnd() async throws {
        let (lib, _) = try makeLibrary()
        let found = try await ids(lib, "sent yesterday")
        XCTAssertEqual(found, [10, 11])
        let narrower = try await ids(lib, "sent category")
        XCTAssertEqual(narrower, [])
    }

    func testSanitizedFallbackForInputThatIsNotValidFTS5() async throws {
        let (lib, _) = try makeLibrary()
        let query = try XCTUnwrap(FTSQuery.make("C++"))
        let token = lib.beginSearch()
        let set = try await lib.searchBooks(query, token: token)
        XCTAssertTrue(set.usedSanitizedFallback)
        XCTAssertEqual(set.bookIDs.sorted(), [17])

        let quote = try XCTUnwrap(FTSQuery.make("a \"b"))
        let second = try await lib.searchBooks(quote, token: lib.beginSearch())
        XCTAssertTrue(second.usedSanitizedFallback)   // must not throw
    }

    func testValidRawQueryDoesNotReportFallback() async throws {
        let (lib, _) = try makeLibrary()
        let query = try XCTUnwrap(FTSQuery.make("resume"))
        let set = try await lib.searchBooks(query, token: lib.beginSearch())
        XCTAssertFalse(set.usedSanitizedFallback)
    }

    func testStemmedQueryIsRejectedUntilStemmingExists() async throws {
        let (lib, _) = try makeLibrary()
        let query = try XCTUnwrap(FTSQuery.make("run", stemmed: true))
        do {
            _ = try await lib.searchBooks(query, token: lib.beginSearch())
            XCTFail("expected tokenizerUnavailable")
        } catch {
            XCTAssertEqual(error as? FTSSearchError, .tokenizerUnavailable)
        }
    }

    // MARK: - Phase 2

    func testSnippetsAreHighlightedAndOnePerMatchingFormat() async throws {
        let (lib, _) = try makeLibrary()
        let query = try XCTUnwrap(FTSQuery.make("one"))
        let snippets = try await lib.snippets(bookID: 14, query: query, token: lib.beginSearch())
        XCTAssertEqual(Set(snippets.map(\.format)), ["EPUB", "PDF"])
        XCTAssertEqual(snippets.count, 2)
        for snippet in snippets {
            XCTAssertEqual(snippet.bookID, 14)
            XCTAssertTrue(snippet.text.contains("\u{1D}"), "no highlight markers in \(snippet.text)")
        }
    }

    func testSnippetTokenCountAboveCapDoesNotError() async throws {
        let (lib, _) = try makeLibrary()
        let query = try XCTUnwrap(FTSQuery.make("one"))
        let snippets = try await lib.snippets(bookID: 14, query: query, token: lib.beginSearch(), snippetTokens: 500)
        XCTAssertFalse(snippets.isEmpty)
    }

    func testSnippetsEmptyInLikeFallbackMode() async throws {
        let root = try makeRoot()
        let writer = try Connection(ftsPath(root))
        try writer.execute("PRAGMA user_version = 2")
        let lib = try XCTUnwrap(CalibreFTSLibrary(libraryURL: root))
        let query = try XCTUnwrap(FTSQuery.make("one"))
        let snippets = try await lib.snippets(bookID: 14, query: query, token: lib.beginSearch())
        XCTAssertEqual(snippets, [])
    }

    // MARK: - Cancellation

    func testStaleTokenThrowsCancelledImmediately() async throws {
        let (lib, _) = try makeLibrary()
        let query = try XCTUnwrap(FTSQuery.make("one"))
        let stale = lib.beginSearch()
        _ = lib.beginSearch()   // supersedes `stale`
        do {
            _ = try await lib.searchBooks(query, token: stale)
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? FTSSearchError, .cancelled)
        }
    }

    func testInterruptAbortsARunningScan() async throws {
        // Timing-based, so thresholds are generous. A LIKE scan over large documents gives
        // the interrupt something to abort; if the machine is fast enough that the scan ends
        // before the interrupt lands, the test is skipped rather than failed.
        let filler = String(repeating: "alpha beta gamma delta ", count: 5_000)   // about 115 KB
        let docs = (1...400).map { FTSTestFixture.Document(id: $0, book: $0, format: "EPUB", text: filler) }
        let root = try makeRoot(docs)
        let writer = try Connection(ftsPath(root))
        try writer.execute("PRAGMA user_version = 2")   // LIKE mode: full scan of searchable_text
        let lib = try XCTUnwrap(CalibreFTSLibrary(libraryURL: root))
        let query = try XCTUnwrap(FTSQuery.make("no such phrase anywhere"))

        let token = lib.beginSearch()
        let started = Date()
        let search = Task { try await lib.searchBooks(query, token: token) }
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = lib.beginSearch()
        do {
            _ = try await search.value
            throw XCTSkip("scan finished before the interrupt landed")
        } catch let error as FTSSearchError {
            XCTAssertEqual(error, .cancelled)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
        }
    }

    // MARK: - Busy

    func testExclusiveWriterProducesBusy() async throws {
        let (lib, root) = try makeLibrary()
        await lib.setBusyTimeoutForTesting(0.05)
        let writer = try Connection(ftsPath(root))
        try writer.execute("BEGIN EXCLUSIVE")
        defer { try? writer.execute("ROLLBACK") }
        let query = try XCTUnwrap(FTSQuery.make("one"))
        do {
            _ = try await lib.searchBooks(query, token: lib.beginSearch())
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? FTSSearchError, .busy)
        }
    }

    // MARK: - Data version (G5)

    func testDataVersionChangesWhenAnotherConnectionCommits() throws {
        let root = try makeRoot()
        let reader = try FTSTestFixture.openReader(root: root)
        func version() throws -> Int64? { try reader.scalar("PRAGMA data_version") as? Int64 }
        let before = try version()
        let writer = try Connection(ftsPath(root))
        try CalibreTokenizerRegistration.register(on: writer)
        try writer.run(
            "INSERT INTO books_text (id, book, timestamp, format, format_hash, searchable_text) VALUES (99, 99, 0, 'EPUB', 'h', 'new row')"
        )
        let after = try version()
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, after, "G5: data_version did not change on a read-only connection")
    }

    // MARK: - Index progress

    func testIndexProgressCountsQueueAndRows() async throws {
        let (lib, root) = try makeLibrary()
        let before = try await lib.indexProgress()
        XCTAssertEqual(before.indexed, Self.documents.count)
        let writer = try Connection(ftsPath(root))
        try writer.run("INSERT INTO dirtied_formats (book, format) VALUES (500, 'EPUB')")
        let after = try await lib.indexProgress()
        XCTAssertEqual(after.queued, before.queued + 1)
        XCTAssertFalse(after.isComplete)
    }

    func testAlmostCompleteBoundaryIsTenPercent() {
        XCTAssertFalse(FTSIndexProgress(indexed: 9, queued: 1).isAlmostComplete)    // exactly 10 percent
        XCTAssertTrue(FTSIndexProgress(indexed: 10, queued: 1).isAlmostComplete)    // below 10 percent
        XCTAssertFalse(FTSIndexProgress(indexed: 0, queued: 0).isAlmostComplete)
        XCTAssertTrue(FTSIndexProgress(indexed: 5, queued: 0).isComplete)
    }

    // MARK: - File replacement (D19)

    func testSearchSeesRecreatedFileAndStampChanges() async throws {
        let (lib, root) = try makeLibrary()
        let query = try XCTUnwrap(FTSQuery.make("resume"))
        let first = try await lib.searchBooks(query, token: lib.beginSearch())
        XCTAssertEqual(first.bookIDs.sorted(), [10, 11])

        // Calibre's re-index deletes and recreates the file.
        try FTSTestFixture.writeLibrary(at: root, books: [
            .init(id: 1, book: 77, format: "EPUB", text: "a fresh resume appears")
        ])
        let second = try await lib.searchBooks(query, token: lib.beginSearch())
        XCTAssertEqual(second.bookIDs, [77])
        XCTAssertNotEqual(first.stamp, second.stamp)
    }

    func testMissingFileThrowsAndRecoversWhenItReappears() async throws {
        let (lib, root) = try makeLibrary()
        try FileManager.default.removeItem(atPath: ftsPath(root))
        let query = try XCTUnwrap(FTSQuery.make("resume"))
        do {
            _ = try await lib.searchBooks(query, token: lib.beginSearch())
            XCTFail("expected an error while the file is missing")
        } catch {
            guard case .sqlite = error as? FTSSearchError else {
                return XCTFail("expected .sqlite, got \(error)")
            }
        }
        try FTSTestFixture.writeLibrary(at: root, books: [
            .init(id: 1, book: 5, format: "EPUB", text: "resume again")
        ])
        let found = try await lib.searchBooks(query, token: lib.beginSearch())
        XCTAssertEqual(found.bookIDs, [5])
    }

    // MARK: - Error mapping

    private func map(_ error: Error, token: SearchToken? = nil, control: SearchControl = SearchControl(handle: nil)) -> FTSSearchError {
        CalibreFTSLibrary.mapError(error, token: token, control: control)
    }

    func testErrorMappingByResultCode() {
        func result(_ code: Int32, _ message: String) -> Error {
            SQLite.Result.error(message: message, code: code, statement: nil)
        }
        XCTAssertEqual(map(result(9, "interrupted")), .cancelled)
        XCTAssertEqual(map(result(5, "database is locked")), .busy)
        XCTAssertEqual(map(result(6, "table is locked")), .busy)
        XCTAssertEqual(map(result(1, "fts5: syntax error near \"+\"")), .syntax("fts5: syntax error near \"+\""))
        XCTAssertEqual(map(result(1, "unterminated string")), .syntax("unterminated string"))
        XCTAssertEqual(map(result(1, "no such column: foo")), .syntax("no such column: foo"))
        XCTAssertEqual(map(result(1, "no such table: nope")), .sqlite(code: 1, message: "no such table: nope"))
        XCTAssertEqual(map(result(8, "attempt to write a readonly database")),
                       .sqlite(code: 8, message: "attempt to write a readonly database"))
    }

    func testExtendedCodesMapToTheirPrimaryCode() {
        // SQLITE_BUSY_SNAPSHOT = 517 = 5 | (2 << 8)
        let busy = SQLite.Result.extendedError(message: "busy", extendedCode: 517, statement: nil)
        XCTAssertEqual(map(busy), .busy)
        // SQLITE_READONLY_CANTINIT = 1288 = 8 | (5 << 8)
        let readonly = SQLite.Result.extendedError(message: "ro", extendedCode: 1288, statement: nil)
        XCTAssertEqual(map(readonly), .sqlite(code: 8, message: "ro"))
    }

    func testStaleTokenWinsOverAnyOtherError() {
        let control = SearchControl(handle: nil)
        let token = control.begin()
        _ = control.begin()
        let error = SQLite.Result.error(message: "database is locked", code: 5, statement: nil)
        XCTAssertEqual(map(error, token: token, control: control), .cancelled)
    }

    func testFTSErrorsPassThroughUnchanged() {
        XCTAssertEqual(map(FTSSearchError.busy), .busy)
    }
}
