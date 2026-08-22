import XCTest
@testable import Ambrosia

// Covers AnnotationExportManager.exportToCSV, the pure formatting half of
// annotation export (closing the "Annotation export/sharing" line from
// docs/not-yet-built.md — see docs/annotations.md). buildExportRows/
// presentExportPanel are not covered here: both require a live
// LibrarySession (actor-backed AmbrosiaMetaDB + CalibreLibrary) or AppKit
// panel presentation, neither of which this pure-function test needs.
// Only the fields exportToCSV actually reads are populated on the
// CalibreBook fixture, matching the convention established in
// LibraryQueryHelpersTests.
final class AnnotationExportManagerTests: XCTestCase {

    private func makeBook(id: Int, title: String, authors: [String]) -> CalibreBook {
        CalibreBook(
            id: id,
            title: title,
            series: nil,
            seriesIndex: nil,
            wordCount: nil,
            kudos: nil,
            publishedDate: nil,
            publisher: nil,
            relativePath: "Author/\(title)",
            authors: authors,
            tags: [],
            comment: nil
        )
    }

    private func makeAnnotation(
        spineIndex: Int = 0,
        startChar: Int = 10,
        endChar: Int = 20,
        selectedText: String = "some highlighted text",
        note: String? = nil,
        colorHex: String = "#FFD60A"
    ) -> Annotation {
        Annotation(
            spineIndex: spineIndex,
            startChar: startChar,
            endChar: endChar,
            selectedText: selectedText,
            note: note,
            colorHex: colorHex
        )
    }

    func testHeaderRow() {
        let csv = AnnotationExportManager.exportToCSV(rows: [])
        let header = csv.components(separatedBy: "\r\n").first
        XCTAssertEqual(
            header,
            "Book Title,Authors,Type,Selected Text,Note,Color,Spine Index,Created Date"
        )
    }

    func testHighlightRowFields() {
        let book = makeBook(id: 1, title: "A Study in Scarlet", authors: ["A. Author"])
        let annotation = makeAnnotation(selectedText: "the game is afoot", note: "great line")
        let row = AnnotationExportRow(annotation: annotation, book: book)

        let csv = AnnotationExportManager.exportToCSV(rows: [row])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)

        let fields = lines[1].components(separatedBy: ",")
        XCTAssertEqual(fields[0], "A Study in Scarlet")
        XCTAssertEqual(fields[1], "A. Author")
        // A non-point annotation (startChar != endChar) is a Highlight.
        XCTAssertEqual(fields[2], "Highlight")
    }

    func testPointAnnotationIsLabeledBookmark() {
        let book = makeBook(id: 2, title: "Bookmarked Work", authors: [])
        // startChar == endChar makes this a point annotation (old-style bookmark).
        let annotation = makeAnnotation(startChar: 5, endChar: 5, selectedText: "")
        let row = AnnotationExportRow(annotation: annotation, book: book)

        let csv = AnnotationExportManager.exportToCSV(rows: [row])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let fields = lines[1].components(separatedBy: ",")
        XCTAssertEqual(fields[2], "Bookmark")
    }

    func testMultipleAuthorsAreSemicolonJoined() {
        let book = makeBook(id: 3, title: "Collab Fic", authors: ["Author One", "Author Two"])
        let row = AnnotationExportRow(annotation: makeAnnotation(), book: book)

        let csv = AnnotationExportManager.exportToCSV(rows: [row])
        XCTAssertTrue(csv.contains("Author One; Author Two"))
    }

    func testFieldsContainingCommasAreQuoted() {
        let book = makeBook(id: 4, title: "Title, With Comma", authors: [])
        let annotation = makeAnnotation(note: "note, with comma too")
        let row = AnnotationExportRow(annotation: annotation, book: book)

        let csv = AnnotationExportManager.exportToCSV(rows: [row])
        XCTAssertTrue(csv.contains("\"Title, With Comma\""))
        XCTAssertTrue(csv.contains("\"note, with comma too\""))
    }

    func testMissingNoteExportsAsEmptyField() {
        let book = makeBook(id: 5, title: "No Note", authors: [])
        let row = AnnotationExportRow(annotation: makeAnnotation(note: nil), book: book)

        let csv = AnnotationExportManager.exportToCSV(rows: [row])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let fields = lines[1].components(separatedBy: ",")
        // Note column (index 4) is empty when annotation.note is nil.
        XCTAssertEqual(fields[4], "")
    }

    func testRowOrderIsPreserved() {
        let book = makeBook(id: 6, title: "Ordered Book", authors: [])
        let first = AnnotationExportRow(annotation: makeAnnotation(spineIndex: 0), book: book)
        let second = AnnotationExportRow(annotation: makeAnnotation(spineIndex: 1), book: book)

        let csv = AnnotationExportManager.exportToCSV(rows: [first, second])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3) // header + 2 rows
        XCTAssertTrue(lines[1].contains(",0,"))
        XCTAssertTrue(lines[2].contains(",1,"))
    }
}
