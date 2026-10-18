// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

private final class GoldenBundleToken {}

final class CalibreTokenizerTests: XCTestCase {

    /// Compact (text, start, end, colocated) tuples for readable assertions.
    private func summary(_ tokens: [CalibreToken]) -> [String] {
        tokens.map { "\($0.text)|\($0.start)|\($0.end)|\($0.colocated ? "co" : "")" }
    }

    // MARK: - Calibre's own cases (src/calibre/db/tests/fts.py, test_fts_tokenize)

    func testAccentedWordEmitsColocatedStrippedToken() {
        let tokens = CalibreTokenizer.tokenize("Some w\u{00F6}rds", nfkc: true)
        XCTAssertEqual(summary(tokens), ["some|0|4|", "w\u{00F6}rds|5|11|", "words|5|11|co"])
    }

    func testApostropheInsideWordIsKeptAndQuotesAreDropped() {
        XCTAssertEqual(summary(CalibreTokenizer.tokenize("don't 'bug'", nfkc: true)), ["don't|0|5|", "bug|7|10|"])
    }

    func testPunctuationSeparators() {
        XCTAssertEqual(summary(CalibreTokenizer.tokenize("a,b. c", nfkc: true)), ["a|0|1|", "b|2|3|", "c|5|6|"])
        XCTAssertEqual(summary(CalibreTokenizer.tokenize("a*b+c", nfkc: true)), ["a|0|1|", "b|2|3|", "c|4|5|"])
        XCTAssertEqual(summary(CalibreTokenizer.tokenize("a(b[{^c", nfkc: true)), ["a|0|1|", "b|2|3|", "c|6|7|"])
    }

    func testEmojiIsAToken() {
        XCTAssertEqual(
            summary(CalibreTokenizer.tokenize("a\u{1F600}smile", nfkc: true)),
            ["a|0|1|", "\u{1F600}|1|5|", "smile|5|10|"]
        )
    }

    // MARK: - Mode and options

    func testQueryModeEmitsNoColocatedToken() {
        let tokens = CalibreTokenizer.tokenize("Some w\u{00F6}rds", mode: .query)
        XCTAssertEqual(summary(tokens), ["some|0|4|", "w\u{00F6}rds|5|11|"])
    }

    func testAuxModeEmitsNoColocatedToken() {
        XCTAssertFalse(CalibreTokenizer.tokenize("caf\u{00E9}", mode: .aux).contains { $0.colocated })
    }

    func testRemoveDiacriticsOffEmitsNoColocatedToken() {
        let tokens = CalibreTokenizer.tokenize("caf\u{00E9}", removeDiacritics: false)
        XCTAssertEqual(summary(tokens), ["caf\u{00E9}|0|5|"])
    }

    func testPlainAsciiHasNoColocatedToken() {
        XCTAssertEqual(summary(CalibreTokenizer.tokenize("Dragon")), ["dragon|0|6|"])
    }

    func testCombiningMarkSequenceStripsToBase() {
        // c o + U+1ED9 (o with circumflex and dot below) + l
        let tokens = CalibreTokenizer.tokenize("co\u{1ED9}l")
        XCTAssertEqual(tokens.map(\.text), ["co\u{1ED9}l", "cool"])
        XCTAssertEqual(tokens.map(\.colocated), [false, true])
    }

    func testFullCaseFolding() {
        XCTAssertEqual(CalibreTokenizer.tokenize("Stra\u{00DF}e", mode: .query).map(\.text), ["strasse"])
    }

    // MARK: - Script blocks

    func testHanSplitsFromLatin() {
        let tokens = CalibreTokenizer.tokenize("\u{4F60}don't\u{53EB}mess")
        XCTAssertEqual(
            summary(tokens),
            ["\u{4F60}|0|3|", "don't|3|8|", "\u{53EB}|8|11|", "mess|11|15|"]
        )
    }

    func testCalibreHanSegmentationCases() {
        // Cases from calibre src/calibre/db/tests/fts.py test_fts_tokenize.
        func texts(_ input: String, mode: CalibreTokenizer.Mode = .query) -> [String] {
            CalibreTokenizer.tokenize(input, mode: mode).map(\.text)
        }
        XCTAssertEqual(texts("\u{4F60}don't\u{53EB}mess", mode: .document), ["\u{4F60}", "don't", "\u{53EB}", "mess"])
        XCTAssertEqual(texts("\u{4F60}don't\u{53EB}mess"), ["\u{4F60}", "don't", "\u{53EB}", "mess"])
        XCTAssertEqual(
            texts("\u{4F60}\u{53EB}\u{4EC0}\u{4E48}\u{540D}\u{5B57}"),
            ["\u{4F60}", "\u{53EB}", "\u{4EC0}\u{4E48}", "\u{540D}\u{5B57}"]
        )
        XCTAssertEqual(texts("\u{4F60}\u{53EB}abc"), ["\u{4F60}", "\u{53EB}", "abc"])
        XCTAssertEqual(
            texts("a\u{4F60}b\u{53EB}\u{4EC0}\u{4E48}\u{540D}\u{5B57}"),
            ["a", "\u{4F60}", "b", "\u{53EB}", "\u{4EC0}\u{4E48}", "\u{540D}\u{5B57}"]
        )
    }

    func testCalibreApostropheCases() {
        XCTAssertEqual(CalibreTokenizer.tokenize("don't 'its' w\u{00F6}rds").map(\.text), ["don't", "its", "w\u{00F6}rds", "words"])
        XCTAssertEqual(CalibreTokenizer.tokenize("l'hospital").map(\.text), ["l'hospital"])
        XCTAssertEqual(CalibreTokenizer.tokenize("x'bug'").map(\.text), ["x'bug"])
    }

    func testHanAndKanaAreSeparateBlocks() {
        // Han and Hiragana map to different iterator languages, so they never share a segment.
        let tokens = CalibreTokenizer.tokenize("\u{65E5}\u{672C}\u{3067}\u{3059}", mode: .query)
        XCTAssertGreaterThanOrEqual(tokens.count, 2)
        for token in tokens {
            let scalars = token.text.unicodeScalars
            let hasHan = scalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let hasKana = scalars.contains { (0x3040...0x309F).contains($0.value) }
            XCTAssertFalse(hasHan && hasKana, "token \(token.text) mixes Han and kana")
        }
    }

    // MARK: - Edge cases

    func testEmptyAndWhitespaceOnlyInputYieldNoTokens() {
        XCTAssertTrue(CalibreTokenizer.tokenize("").isEmpty)
        XCTAssertTrue(CalibreTokenizer.tokenize("  \n\t ").isEmpty)
        XCTAssertTrue(CalibreTokenizer.tokenize("--- ... !!!").isEmpty)
    }

    func testOffsetsAreMonotonicAndInBounds() {
        let text = "Hello \u{4E16}\u{754C} caf\u{00E9} \u{1F600} na\u{00EF}ve \u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}"
        let byteCount = text.utf8.count
        var previousEnd = 0
        for token in CalibreTokenizer.tokenize(text) where !token.colocated {
            XCTAssertGreaterThanOrEqual(token.start, previousEnd)
            XCTAssertGreaterThan(token.end, token.start)
            XCTAssertLessThanOrEqual(token.end, byteCount)
            previousEnd = token.end
        }
    }

    func testLargeInputCompletesQuickly() {
        let words = (0..<150_000).map { "word\($0 % 97)" }
        let text = words.joined(separator: " ")
        XCTAssertGreaterThan(text.utf8.count, 1_000_000)
        let started = Date()
        let tokens = CalibreTokenizer.tokenize(text, mode: .query)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(tokens.count, words.count)
        // Generous bound: this guards against per-token allocation or quadratic behavior,
        // not against ordinary machine variance.
        XCTAssertLessThan(elapsed, 20)
    }

    // MARK: - Golden corpus (generated by scripts/gen_calibre_tokenizer_golden.py)

    private struct Golden: Decodable {
        struct Meta: Decodable {
            let icu_version: String
            let unicode_version: String
            let calibre_version: String
        }
        struct Case: Decodable {
            struct Tok: Decodable {
                let text: String
                let start: Int
                let end: Int
                let flags: Int
            }
            let text: String
            let mode: String
            let remove_diacritics: Bool
            let tokens: [Tok]
            let known_divergence: Bool?
            let divergence_reason: String?
        }
        let meta: Meta
        let cases: [Case]
    }

    func testGoldenCorpus() throws {
        let bundle = Bundle(for: GoldenBundleToken.self)
        guard let url = bundle.url(forResource: "calibre_tokenizer_golden", withExtension: "json") else {
            throw XCTSkip("calibre_tokenizer_golden.json not generated yet; see scripts/gen_calibre_tokenizer_golden.py")
        }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        var failures: [String] = []
        for testCase in golden.cases {
            let mode: CalibreTokenizer.Mode = testCase.mode == "query" ? .query : .document
            let actual = CalibreTokenizer.tokenize(testCase.text, mode: mode, removeDiacritics: testCase.remove_diacritics)
            if testCase.known_divergence == true {
                var previousEnd = 0
                for token in actual where !token.colocated {
                    if token.start < previousEnd || token.end <= token.start {
                        failures.append("offsets not monotonic for known-divergent case \(testCase.text.debugDescription)")
                        break
                    }
                    previousEnd = token.end
                }
                continue
            }
            let expected = testCase.tokens.map { "\($0.text)|\($0.start)|\($0.end)|\($0.flags != 0 ? "co" : "")" }
            if summary(actual) != expected {
                failures.append("\(testCase.mode) \(testCase.text.prefix(40).debugDescription)")
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "golden mismatches (calibre ICU \(golden.meta.icu_version), unicode \(golden.meta.unicode_version); "
                + "this machine's runtime differs): \(failures.prefix(10))"
        )
    }
}
