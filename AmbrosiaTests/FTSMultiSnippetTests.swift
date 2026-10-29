// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SQLite
@testable import Ambrosia

final class FTSMultiSnippetTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    // MARK: - Term extraction tests

    func testExtractSearchTermsFromQuotedPhrase() throws {
        let query = try XCTUnwrap(FTSQuery.make("\"slow burn\""))
        let terms = FTSOccurrenceExtractor.extractSearchTerms(from: query)
        XCTAssertEqual(terms, ["slow burn"])
    }

    func testExtractSearchTermsFromMultipleWordsAndOperators() throws {
        let query = try XCTUnwrap(FTSQuery.make("harry AND hermione OR \"ron weasley\" NOT voldemort"))
        let terms = FTSOccurrenceExtractor.extractSearchTerms(from: query)
        XCTAssertEqual(terms, ["harry", "hermione", "ron weasley", "voldemort"])
    }

    func testExtractSearchTermsStripsPrefixWildcards() throws {
        let query = try XCTUnwrap(FTSQuery.make("magic* AND dragon*"))
        let terms = FTSOccurrenceExtractor.extractSearchTerms(from: query)
        XCTAssertEqual(terms, ["magic", "dragon"])
    }

    // MARK: - Multi-snippet windowing & capping tests

    func testExtractSnippetsCapsAtMaxAndCountsTotal() throws {
        let text = """
        Chapter 1: The magic began in the quiet village.
        Chapter 2: More magic happened under the moonlight.
        Chapter 3: Ancient magic was discovered in the cellar.
        Chapter 4: Dark magic spread across the enchanted forest.
        Chapter 5: Lost magic returned to the kingdom.
        Chapter 6: Deep magic resonated within the stones.
        Chapter 7: Final magic broke the ancient curse.
        """
        let query = try XCTUnwrap(FTSQuery.make("magic"))
        let result = FTSOccurrenceExtractor.extract(
            text: text,
            textRowID: 1,
            bookID: 10,
            format: "EPUB",
            query: query,
            maxSnippets: 5,
            radiusCharacters: 40
        )

        XCTAssertEqual(result.totalOccurrences, 7, "Must accurately report total occurrences")
        XCTAssertEqual(result.snippets.count, 5, "Must cap returned snippets at maxSnippets")

        for (idx, snippet) in result.snippets.enumerated() {
            XCTAssertEqual(snippet.id, idx)
            XCTAssertTrue(snippet.text.contains("\u{1D}magic\u{1D}"), "Must wrap matching term with marker")
            XCTAssertGreaterThanOrEqual(snippet.approximatePercent, 0.0)
            XCTAssertLessThanOrEqual(snippet.approximatePercent, 1.0)
        }
    }

    func testExtractSnippetsWithQuotedPhrase() throws {
        let text = "It was an agonizing slow burn that lasted for years before they finally spoke."
        let query = try XCTUnwrap(FTSQuery.make("\"slow burn\""))
        let result = FTSOccurrenceExtractor.extract(
            text: text,
            textRowID: 2,
            bookID: 20,
            format: "EPUB",
            query: query,
            maxSnippets: 5
        )

        XCTAssertEqual(result.totalOccurrences, 1)
        XCTAssertEqual(result.snippets.count, 1)
        XCTAssertTrue(result.snippets[0].text.contains("\u{1D}slow burn\u{1D}"))
    }

    func testExtractSnippetsBoundaryBeginningAndEnd() throws {
        let text = "StartWord in the middle of sentences ending with EndWord"
        let query = try XCTUnwrap(FTSQuery.make("StartWord EndWord"))
        let result = FTSOccurrenceExtractor.extract(
            text: text,
            textRowID: 3,
            bookID: 30,
            format: "EPUB",
            query: query,
            maxSnippets: 5
        )

        XCTAssertEqual(result.totalOccurrences, 2)
        XCTAssertEqual(result.snippets.count, 2)
        XCTAssertTrue(result.snippets[0].text.contains("\u{1D}StartWord\u{1D}"))
        XCTAssertTrue(result.snippets[1].text.contains("\u{1D}EndWord\u{1D}"))
    }

    // MARK: - CalibreFTSLibrary integration test

    private func makeLibrary(_ docs: [FTSTestFixture.Document]) throws -> (CalibreFTSLibrary, URL) {
        let root = try FTSTestFixture.makeLibraryRoot(books: docs)
        roots.append(root)
        let lib = try XCTUnwrap(CalibreFTSLibrary(libraryURL: root))
        return (lib, root)
    }

    func testLibraryMultiSnippetsReturnsOccurrences() async throws {
        let longText = """
        The first lighthouse shone bright over the ocean.
        The keeper watched the storm brewing on the horizon.
        The second lighthouse answered with its synchronized beam.
        Miles away, a third lighthouse pierced through the dense fog.
        Sailors relied on the lighthouse to guide them through the reef.
        """
        let docs: [FTSTestFixture.Document] = [
            .init(id: 1, book: 42, format: "EPUB", text: longText)
        ]
        let (lib, _) = try makeLibrary(docs)
        let query = try XCTUnwrap(FTSQuery.make("lighthouse"))
        let token = lib.beginSearch()

        let results = try await lib.multiSnippets(bookID: 42, query: query, token: token, maxSnippets: 3)
        XCTAssertEqual(results.count, 1)
        let epubResult = results[0]
        XCTAssertEqual(epubResult.bookID, 42)
        XCTAssertEqual(epubResult.format, "EPUB")
        XCTAssertEqual(epubResult.totalOccurrences, 4)
        XCTAssertEqual(epubResult.snippets.count, 3)

        for snippet in epubResult.snippets {
            XCTAssertTrue(snippet.text.contains("\u{1D}lighthouse\u{1D}"))
        }
    }
}
