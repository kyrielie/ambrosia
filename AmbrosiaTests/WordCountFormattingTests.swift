import XCTest
@testable import Ambrosia

final class WordCountFormattingTests: XCTestCase {

    func testBelowOneThousandIsShownExactly() {
        XCTAssertEqual(WordCountFormatting.label(0), "0 words")
        XCTAssertEqual(WordCountFormatting.label(850), "850 words")
        XCTAssertEqual(WordCountFormatting.label(999), "999 words")
    }

    func testThousandsUseOneDecimalAndKSuffix() {
        XCTAssertEqual(WordCountFormatting.label(1_000), "1.0k words")
        XCTAssertEqual(WordCountFormatting.label(12_300), "12.3k words")
    }

    func testMillionsUseTwoDecimalsAndMSuffix() {
        XCTAssertEqual(WordCountFormatting.label(1_000_000), "1.00M words")
        XCTAssertEqual(WordCountFormatting.label(1_250_000), "1.25M words")
    }
}
