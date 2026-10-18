// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class FTSQueryTests: XCTestCase {

    private func make(_ text: String) throws -> FTSQuery {
        try XCTUnwrap(FTSQuery.make(text))
    }

    func testEmptyAndWhitespaceInputIsNil() {
        XCTAssertNil(FTSQuery.make(""))
        XCTAssertNil(FTSQuery.make(" \t\n"))
    }

    func testNormalizationTrimsAndAppliesNFKC() throws {
        XCTAssertEqual(try make("  dragon \n").normalized, "dragon")
        XCTAssertEqual(try make("\u{FB01}nd").normalized, "find")
        XCTAssertEqual(try make("\u{FF46}\u{FF55}\u{FF4C}\u{FF4C}").normalized, "full")
        // Compare scalars: Swift String equality is canonical-equivalence based.
        let decomposed = try make("re\u{0301}sume\u{0301}").normalized
        XCTAssertEqual(Array(decomposed.unicodeScalars), Array("r\u{00E9}sum\u{00E9}".unicodeScalars))
    }

    func testCacheKeyDistinguishesAccentsAndCase() throws {
        XCTAssertNotEqual(try make("resume").cacheKey, try make("r\u{00E9}sum\u{00E9}").cacheKey)
        XCTAssertNotEqual(try make("AND").cacheKey, try make("and").cacheKey)
    }

    func testCacheKeySeparatesStemmedFromUnstemmed() throws {
        let plain = try make("run")
        let stemmed = try XCTUnwrap(FTSQuery.make("run", stemmed: true))
        XCTAssertNotEqual(plain.cacheKey, stemmed.cacheKey)
    }

    func testRawExpressionIsTheNormalizedInput() throws {
        XCTAssertEqual(try make("moose OR one").rawMatchExpression, "moose OR one")
        XCTAssertEqual(try make("conn*").rawMatchExpression, "conn*")
    }

    func testSanitizedExpressionQuotesEachPiece() throws {
        XCTAssertEqual(try make("C++").sanitizedMatchExpression, "\"C++\"")
        XCTAssertEqual(try make("one   two").sanitizedMatchExpression, "\"one\" \"two\"")
        XCTAssertEqual(try make("moose OR one").sanitizedMatchExpression, "\"moose\" \"OR\" \"one\"")
    }

    func testSanitizedExpressionDoublesEmbeddedQuotes() throws {
        XCTAssertEqual(try make("a \"b").sanitizedMatchExpression, "\"a\" \"\"\"b\"")
    }

    func testSanitizedExpressionNeutralizesOperators() throws {
        let query = try make("^one NEAR(a b) -x")
        // Every piece ends up inside quotes, so no operator survives unquoted.
        for piece in query.sanitizedMatchExpression.split(separator: " ") {
            XCTAssertTrue(piece.hasPrefix("\""), "unquoted piece: \(piece)")
        }
    }
}
