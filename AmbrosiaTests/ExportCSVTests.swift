import XCTest
@testable import Ambrosia

final class ExportCSVTests: XCTestCase {

    func testCSVEscapeLeavesPlainTextUnquoted() {
        XCTAssertEqual(ExportManager.csvEscape("Simple Title"), "Simple Title")
    }

    func testCSVEscapeQuotesCommasAndDoublesQuotes() {
        XCTAssertEqual(ExportManager.csvEscape("A, \"Quoted\" Work"), "\"A, \"\"Quoted\"\" Work\"")
    }

    func testCSVEscapeReplacesNewlinesWithSpaces() {
        XCTAssertEqual(ExportManager.csvEscape("Line 1\r\nLine 2\nLine 3\rLine 4"), "Line 1 Line 2 Line 3 Line 4")
    }

    func testCSVRowJoinsEscapedFields() {
        let row = ExportManager.csvRow(["Title", "Author, One", "He said \"Hi\""])
        XCTAssertEqual(row, "Title,\"Author, One\",\"He said \"\"Hi\"\"\"")
    }
}
