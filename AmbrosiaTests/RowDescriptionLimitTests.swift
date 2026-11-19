import XCTest
@testable import Ambrosia

/// Coverage for `RowDescriptionLimit.capped(_:limit:)` (`BookListRow.swift`),
/// the view-side description truncation used by list rows.
final class RowDescriptionLimitTests: XCTestCase {

    private func makeBook(id: Int, title: String, comment: String?) -> CalibreBook {
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
            authors: [],
            tags: [],
            comment: comment
        )
    }

    func testEmptyStringIsUnchanged() {
        XCTAssertEqual(RowDescriptionLimit.capped(""), "")
    }

    func testShortStringIsUnchanged() {
        XCTAssertEqual(RowDescriptionLimit.capped("A short summary."), "A short summary.")
    }

    func testExactlyAtLimitIsUnchanged() {
        let text = String(repeating: "a", count: RowDescriptionLimit.characters)
        XCTAssertEqual(RowDescriptionLimit.capped(text), text)
    }

    func testOneOverLimitIsTruncatedWithEllipsis() {
        let text = String(repeating: "a", count: RowDescriptionLimit.characters + 1)
        let result = RowDescriptionLimit.capped(text)
        XCTAssertTrue(result.hasSuffix("\u{2026}"))
        XCTAssertEqual(result, String(repeating: "a", count: RowDescriptionLimit.characters - 1) + "\u{2026}")
        XCTAssertEqual(result.count, RowDescriptionLimit.characters)
    }

    func testTrailingWhitespaceIsTrimmedBeforeEllipsis() {
        let text = "abc   def"
        let result = RowDescriptionLimit.capped(text, limit: 6)
        XCTAssertEqual(result, "abc\u{2026}")
    }

    func testEmojiAreNotSplitMidCharacter() {
        let text = String(repeating: "\u{1F600}", count: 10)
        let result = RowDescriptionLimit.capped(text, limit: 4)
        XCTAssertEqual(result, String(repeating: "\u{1F600}", count: 3) + "\u{2026}")
    }

    func testCombiningMarksStayWithBaseCharacter() {
        // "e" + combining acute accent is one Character.
        let unit = "e\u{0301}"
        let text = String(repeating: unit, count: 10)
        let result = RowDescriptionLimit.capped(text, limit: 3)
        XCTAssertEqual(result, String(repeating: unit, count: 2) + "\u{2026}")
    }

    func testCustomLimitBelowLengthTruncates() {
        XCTAssertEqual(RowDescriptionLimit.capped("hello world", limit: 5), "hell\u{2026}")
    }

    func testDescriptionContentDropsBlankSectionsAndKeepsFullText() {
        let content = RowDescriptionContent(sections: [
            .init(title: "First Work", text: "First description."),
            .init(title: "Empty Work", text: " \n "),
            .init(title: "Second Work", text: "Second description.")
        ])

        XCTAssertEqual(content.sections.count, 2)
        XCTAssertEqual(content.fullText, "First Work\nFirst description.\n\nSecond Work\nSecond description.")
        XCTAssertEqual(content.previewText, content.fullText)
        XCTAssertFalse(content.isCharacterTruncated)
    }

    func testSeriesDescriptionUsesTheFinalWorksOrderAndOmitsEmptyComments() {
        let works = [
            makeBook(id: 2, title: "Second", comment: "Second description."),
            makeBook(id: 1, title: "Empty", comment: "  "),
            makeBook(id: 3, title: "Third", comment: "Third description.")
        ]

        let content = RowDescriptionContent.series(works: works)

        XCTAssertEqual(content.sections.map(\.title), ["Second", "Third"])
        XCTAssertEqual(content.sections.map(\.text), ["Second description.", "Third description."])
    }

    func testDescriptionContentCapsEachSeriesWorkBeforeTheTotalLimit() {
        let content = RowDescriptionContent(
            sections: [
                .init(title: "Work 1", text: String(repeating: "a", count: 401)),
                .init(title: "Work 2", text: "Second description.")
            ],
            perSectionCharacterLimit: RowDescriptionContent.perWorkCharacterLimit
        )

        XCTAssertTrue(content.previewText.contains(String(repeating: "a", count: 399) + "…"))
        XCTAssertTrue(content.previewText.hasSuffix("Work 2\nSecond description."))
        XCTAssertTrue(content.isCharacterTruncated)
        XCTAssertTrue(content.fullText.contains(String(repeating: "a", count: 401)))
    }

    func testDescriptionContentCapsTotalPreviewAtTheSharedLimit() {
        let content = RowDescriptionContent.single(String(repeating: "x", count: RowDescriptionLimit.characters + 1))

        XCTAssertEqual(content.previewText.count, RowDescriptionLimit.characters)
        XCTAssertTrue(content.previewText.hasSuffix("…"))
        XCTAssertTrue(content.isCharacterTruncated)
        XCTAssertEqual(content.fullText.count, RowDescriptionLimit.characters + 1)
    }
}
