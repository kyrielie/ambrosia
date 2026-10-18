// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SQLite
@testable import Ambrosia

final class CalibreTokenizerRegistrationTests: XCTestCase {

    private var root: URL?

    private static let documents: [FTSTestFixture.Document] = [
        .init(id: 1, book: 10, format: "EPUB", text: "I sent my r\u{00E9}sum\u{00E9} yesterday"),
        .init(id: 2, book: 11, format: "EPUB", text: "I sent my resume yesterday"),
        .init(id: 3, book: 12, format: "EPUB", text: "The category of cats"),
        .init(id: 4, book: 13, format: "EPUB", text: "\u{4F60}don't\u{53EB}mess"),
        .init(id: 5, book: 16, format: "EPUB", text: "\u{4F60}\u{597D}\u{4E16}\u{754C}"),
        .init(id: 6, book: 14, format: "EPUB", text: "one two three four five"),
        .init(id: 7, book: 15, format: "EPUB", text: "connection connected conn")
    ]

    private static let phaseOneSQL = """
        SELECT DISTINCT bt.book
        FROM books_fts
        JOIN books_text AS bt ON bt.id = books_fts.rowid
        WHERE books_fts MATCH ?1
        """

    override func setUpWithError() throws {
        root = try FTSTestFixture.makeLibraryRoot(books: Self.documents)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func fixtureRoot() throws -> URL {
        try XCTUnwrap(root)
    }

    private func books(_ conn: Connection, match: String) throws -> [Int] {
        // Not `for row in` or `compactMap`: Statement's sequence iterator is try!-based
        // and would trap on the intentional FTS5 syntax errors these tests provoke.
        let stmt = try conn.prepare(Self.phaseOneSQL, match)
        var ids: [Int] = []
        while let row = try stmt.failableNext() {
            if let id = (row[0] as? Int64).map({ Int($0) }) { ids.append(id) }
        }
        return ids.sorted()
    }

    func testRegistrationSucceedsOnFreshConnectionAndTwice() throws {
        let conn = try Connection(.inMemory)
        XCTAssertNoThrow(try CalibreTokenizerRegistration.register(on: conn))
        XCTAssertNoThrow(try CalibreTokenizerRegistration.register(on: conn))
    }

    func testMatchWithoutRegistrationFailsWithNoSuchTokenizer() throws {
        let conn = try Connection(try fixtureRoot().appendingPathComponent(FTSTestFixture.fileName).path, readonly: true)
        XCTAssertThrowsError(try books(conn, match: "resume")) { error in
            XCTAssertTrue(String(describing: error).contains("no such tokenizer"), "unexpected error: \(error)")
        }
    }

    func testAccentSemanticsMatchCalibre() throws {
        let conn = try FTSTestFixture.openReader(root: try fixtureRoot())
        // Query tokens are not accent-stripped; documents index both spellings.
        XCTAssertEqual(try books(conn, match: "resume"), [10, 11])
        XCTAssertEqual(try books(conn, match: "r\u{00E9}sum\u{00E9}"), [10])
    }

    func testTokenSemanticsNotSubstring() throws {
        let conn = try FTSTestFixture.openReader(root: try fixtureRoot())
        XCTAssertEqual(try books(conn, match: "cat"), [])
        XCTAssertEqual(try books(conn, match: "category"), [12])
        XCTAssertEqual(try books(conn, match: "conn*"), [15])
    }

    func testCJKSegmentationFollowsCalibre() throws {
        let conn = try FTSTestFixture.openReader(root: try fixtureRoot())
        // U+4F60 is its own token next to Latin text, but inside the word U+4F60 U+597D
        // ICU's dictionary keeps the two characters together.
        XCTAssertEqual(try books(conn, match: "\u{4F60}"), [13])
        XCTAssertEqual(try books(conn, match: "\u{4F60}\u{597D}"), [16])
    }

    func testRawFTS5SyntaxWorks() throws {
        let conn = try FTSTestFixture.openReader(root: try fixtureRoot())
        XCTAssertEqual(try books(conn, match: "one OR conn*"), [14, 15])
        XCTAssertEqual(try books(conn, match: "^one"), [14])
        XCTAssertEqual(try books(conn, match: "NEAR(one four)"), [14])
        XCTAssertEqual(try books(conn, match: "sent yesterday"), [10, 11])
    }

    func testQuotedPunctuationOnlyPhrasesReturnNoRowsWithoutError() throws {
        let conn = try FTSTestFixture.openReader(root: try fixtureRoot())
        XCTAssertEqual(try books(conn, match: "\"--\""), [])
        XCTAssertEqual(try books(conn, match: "\"\""), [])
        XCTAssertEqual(try books(conn, match: "\"C++\""), [])
    }

    func testMalformedRawSyntaxThrows() throws {
        let conn = try FTSTestFixture.openReader(root: try fixtureRoot())
        XCTAssertThrowsError(try books(conn, match: "C++"))
        XCTAssertThrowsError(try books(conn, match: "a \"b"))
        XCTAssertThrowsError(try books(conn, match: "foo:bar"))
    }

    func testPlanUsesFTS5VirtualTableIndex() throws {
        let conn = try FTSTestFixture.openReader(root: try fixtureRoot())
        let details = try conn.prepare("EXPLAIN QUERY PLAN " + Self.phaseOneSQL, "x")
            .compactMap { $0[3] as? String }
        XCTAssertTrue(details.contains { $0.contains("VIRTUAL TABLE INDEX") }, "plan: \(details)")
        XCTAssertFalse(details.contains { $0.contains("SCAN books_text") }, "plan: \(details)")
    }
}
