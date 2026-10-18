// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

/// Manual benchmark against a real Calibre library (M7, decision D16). Skipped unless
/// `AMBROSIA_FTS_BENCH_LIBRARY` points at a library folder containing
/// `full-text-search.db`. Prints p50 and p95 per query; asserts nothing about absolute
/// times. Run against a COPY of the library: Ambrosia never writes, but a copy keeps
/// Calibre's file locks out of the measurement.
///
///   AMBROSIA_FTS_BENCH_LIBRARY=/path/to/copy ./test.sh --no-lint \
///       --filter AmbrosiaTests/CalibreFTSBenchmarkTests
final class CalibreFTSBenchmarkTests: XCTestCase {

    private static let queries = ["the", "dragon", "\"once upon a time\"", "conn*", "r\u{00E9}sum\u{00E9}", "resume"]
    private static let runs = 20

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return sorted[index]
    }

    private func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    func testPhaseOneAndSnippetTimings() async throws {
        guard let path = ProcessInfo.processInfo.environment["AMBROSIA_FTS_BENCH_LIBRARY"], !path.isEmpty else {
            throw XCTSkip("set AMBROSIA_FTS_BENCH_LIBRARY to a Calibre library folder to run")
        }
        // A fresh open per query gives the cold run; the remaining runs are warm.
        for text in Self.queries {
            let query = try XCTUnwrap(FTSQuery.make(text))
            let lib = try XCTUnwrap(CalibreFTSLibrary(libraryURL: URL(fileURLWithPath: path)))
            let mode = await lib.mode
            XCTAssertEqual(mode, .native, "benchmark needs native mode; got \(mode)")

            var timings: [Double] = []
            var lastIDs: [Int] = []
            for _ in 0..<Self.runs {
                let start = DispatchTime.now()
                let set = try await lib.searchBooks(query, token: lib.beginSearch())
                timings.append(milliseconds(since: start))
                lastIDs = set.bookIDs
            }
            let cold = timings[0]
            let warm = Array(timings.dropFirst()).sorted()
            print(String(format: "[FTS bench] %@  books=%d  cold=%.1f ms  warm p50=%.1f ms  p95=%.1f ms",
                         text, lastIDs.count, cold, percentile(warm, 0.5), percentile(warm, 0.95)))

            // Snippet cost: re-tokenizes whole documents, so this is the direct measure of
            // the C tokenizer's speed. Over 50 ms per book, profile calibre_tokenizer.c first.
            let sample = Array(lastIDs.sorted().prefix(25))
            guard !sample.isEmpty else { continue }
            let start = DispatchTime.now()
            for book in sample {
                _ = try await lib.snippets(bookID: book, query: query, token: lib.beginSearch())
            }
            let perBook = milliseconds(since: start) / Double(sample.count)
            print(String(format: "[FTS bench] %@  snippets: %.1f ms per book over %d books", text, perBook, sample.count))
        }
    }
}
