import XCTest
@testable import Ambrosia

final class NormalizedSeriesNameTests: XCTestCase {
    func testTrimsFoldsCaseAndCollapsesWhitespace() {
        XCTAssertEqual(NormalizedSeriesName.key("  The   Long\nSeries  "), "the long series")
        XCTAssertEqual(NormalizedSeriesName.key("THE LONG SERIES"), "the long series")
    }

    func testPreservesAccentsAndPunctuation() {
        XCTAssertEqual(NormalizedSeriesName.key("Café: A/B"), "café: a/b")
    }
}
