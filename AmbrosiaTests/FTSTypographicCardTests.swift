import XCTest
import SwiftUI
@testable import Ambrosia

final class FTSTypographicCardTests: XCTestCase {

    func testMakeAttributedStringWithHighlights() {
        let text = "Here is a \u{1D}test phrase\u{1D} inside a sentence."
        let attr = FTSTypographicCardView.makeAttributedString(from: text, highlightColor: .accentColor)
        let plain = String(attr.characters)
        XCTAssertEqual(plain, "Here is a test phrase inside a sentence.")

        // Verify the highlighted segment has stronglyEmphasized intent
        var foundEmphasized = false
        for run in attr.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            foundEmphasized = true
            let runText = String(attr.characters[run.range])
            XCTAssertEqual(runText, "test phrase")
            XCTAssertEqual(run.foregroundColor, .accentColor)
        }
        XCTAssertTrue(foundEmphasized)
    }

    func testMakeAttributedStringWithoutHighlights() {
        let text = "Plain sentence with no special markers."
        let attr = FTSTypographicCardView.makeAttributedString(from: text)
        XCTAssertEqual(String(attr.characters), text)

        for run in attr.runs {
            XCTAssertNil(run.inlinePresentationIntent)
        }
    }

    func testMakeAttributedStringMultipleHighlights() {
        let text = "\u{1D}First\u{1D} and \u{1D}Second\u{1D} match."
        let attr = FTSTypographicCardView.makeAttributedString(from: text)
        XCTAssertEqual(String(attr.characters), "First and Second match.")

        var highlightedWords: [String] = []
        for run in attr.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            highlightedWords.append(String(attr.characters[run.range]))
        }
        XCTAssertEqual(highlightedWords, ["First", "Second"])
    }

    func testFormatWordCount() {
        let book = CalibreBook(
            id: 1,
            title: "Test Book",
            series: nil,
            seriesIndex: nil,
            wordCount: 15420,
            kudos: nil,
            publishedDate: nil,
            publisher: nil,
            relativePath: "test/path"
        )
        XCTAssertEqual(book.displayWordCount, "15.4k words")
    }
}
