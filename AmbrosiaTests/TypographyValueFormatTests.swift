import XCTest
@testable import Ambrosia

final class TypographyValueFormatTests: XCTestCase {

    func testFormatNumberNonFiniteReturnsZero() {
        XCTAssertEqual(TypographyValueFormat.formatNumber(value: .nan, fractionDigits: 1), "0")
        XCTAssertEqual(TypographyValueFormat.formatNumber(value: .infinity, fractionDigits: 1), "0")
        XCTAssertEqual(TypographyValueFormat.formatNumber(value: -.infinity, fractionDigits: 0), "0")
    }

    func testFormatNumberZeroFractionDigits() {
        XCTAssertEqual(TypographyValueFormat.formatNumber(value: 14.2, fractionDigits: 0), "14")
        XCTAssertEqual(TypographyValueFormat.formatNumber(value: 14.8, fractionDigits: 0), "15")
    }

    func testFormatNumberTwoFractionDigitsTrailingZeroTrim() {
        XCTAssertEqual(TypographyValueFormat.formatNumber(value: 1.50, fractionDigits: 2), "1.5")
        XCTAssertEqual(TypographyValueFormat.formatNumber(value: 1.25, fractionDigits: 2), "1.25")
    }

    func testClamp() {
        XCTAssertEqual(TypographyValueFormat.clamp(5.0, to: 10.0...20.0), 10.0)
        XCTAssertEqual(TypographyValueFormat.clamp(25.0, to: 10.0...20.0), 20.0)
        XCTAssertEqual(TypographyValueFormat.clamp(15.0, to: 10.0...20.0), 15.0)
    }

    func testSnap() {
        let snapped = TypographyValueFormat.snap(12.3, range: 10.0...20.0, step: 0.5, fractionDigits: 1)
        XCTAssertEqual(snapped, 12.5)
    }
}
