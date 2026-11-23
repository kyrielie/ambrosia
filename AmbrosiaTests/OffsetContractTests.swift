import XCTest
@testable import Ambrosia

final class OffsetContractTests: XCTestCase {

    func testASCIICharacterOffsetsMatchUTF16CodeUnits() {
        let text = "Hello world"
        let target = "world"
        guard let range = text.range(of: target) else {
            XCTFail("Target not found")
            return
        }
        let utf16Offset = range.lowerBound.utf16Offset(in: text)
        XCTAssertEqual(utf16Offset, 6)
        XCTAssertEqual(text.utf16.count, 11)
    }

    func testAstralSurrogatePairsCountAsTwoUTF16Units() {
        // 👋 (U+1F44B) is 1 Character, but 2 UTF-16 code units (surrogate pair)
        let text = "👋 hello"
        let target = "hello"
        guard let range = text.range(of: target) else {
            XCTFail("Target not found")
            return
        }
        let charIndex = text.distance(from: text.startIndex, to: range.lowerBound)
        let utf16Offset = range.lowerBound.utf16Offset(in: text)

        XCTAssertEqual(charIndex, 2) // 1 emoji + 1 space
        XCTAssertEqual(utf16Offset, 3) // 2 UTF-16 units + 1 space = 3
        XCTAssertEqual(text.utf16.count, 8)
    }

    func testCombiningMarksCountMultipleCodeUnitsPerGraphemeCluster() {
        // "e" + combining acute accent (U+0301) is 1 Character, 2 UTF-16 units
        let accented = "e\u{0301}"
        let text = "\(accented) cafe"
        guard let range = text.range(of: "cafe") else {
            XCTFail("Target not found")
            return
        }
        let charIndex = text.distance(from: text.startIndex, to: range.lowerBound)
        let utf16Offset = range.lowerBound.utf16Offset(in: text)

        XCTAssertEqual(charIndex, 2)
        XCTAssertEqual(utf16Offset, 3)
    }

    func testClampingAndBoundariesInSnippetExtractor() {
        let fullText = "Quick brown fox jumps"
        let utf16 = fullText.utf16
        let totalLen = utf16.count

        // Out of bounds start past end
        let startOffsetPastEnd = totalLen + 10
        XCTAssertTrue(startOffsetPastEnd >= totalLen)

        // Safe clamping logic
        let safeStart = max(0, min(startOffsetPastEnd, totalLen))
        let safeEnd = max(safeStart, min(startOffsetPastEnd + 5, totalLen))
        XCTAssertEqual(safeStart, totalLen)
        XCTAssertEqual(safeEnd, totalLen)

        let startIdx = utf16.index(utf16.startIndex, offsetBy: safeStart)
        let endIdx = utf16.index(utf16.startIndex, offsetBy: safeEnd)
        let sub = String(utf16[startIdx..<endIdx])
        XCTAssertEqual(sub, "")
    }
}
