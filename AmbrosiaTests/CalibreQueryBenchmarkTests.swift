// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SQLite
@testable import Ambrosia

/// Pass 0 benchmark measuring cold and warm timings on a synthetic 100k Calibre dataset.
/// Measures:
///   1. `fetchAllMatchingIDs` (unfiltered cold and warm)
///   2. `fetchAllMatchingIDs` (filtered by tag)
///   3. `SeriesMatchExpansion.expand`
///   4. `LibraryVisibilityPolicy.filter`
///   5. Bulk value lookups (word counts, titles)
///   6. Swift in-memory sort (100k items)
///   7. `booksForIDs` (50 IDs)
final class CalibreQueryBenchmarkTests: XCTestCase {

    private static var libraryRoot: URL?
    private static var library: CalibreLibrary?
    private static var totalBooks: Int = 100_000

    // swiftlint:disable:next static_over_final_class
    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["AMBROSIA_RUN_BENCHMARKS"] != nil else {
            return
        }
        if let envCount = ProcessInfo.processInfo.environment["AMBROSIA_BENCH_BOOK_COUNT"],
           let parsed = Int(envCount), parsed > 0 {
            totalBooks = parsed
        }
        do {
            libraryRoot = try CalibreTestFixture.makeSyntheticLibraryRoot(count: totalBooks)
            if let root = libraryRoot {
                library = try CalibreLibrary(root: root)
            }
        } catch {
            XCTFail("Failed to generate synthetic benchmark fixture: \(error)")
        }
    }

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        library = nil
        if let root = libraryRoot {
            try? FileManager.default.removeItem(at: root)
        }
        libraryRoot = nil
        super.tearDown()
    }

    private func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    func testPass0BenchmarkSuite() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["AMBROSIA_RUN_BENCHMARKS"] == nil,
            "set AMBROSIA_RUN_BENCHMARKS=1 to run query benchmarks"
        )
        guard let library = Self.library else {
            XCTFail("Benchmark library not initialized")
            return
        }

        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let filteredQuery = SearchQuery(tagTerms: ["Tag 1"], authorTerms: [], titleTerms: [], plainTerms: [])

        // 1. fetchAllMatchingIDs (cold)
        let t0 = DispatchTime.now()
        let coldIDs = await library.fetchAllMatchingIDs(query: emptyQuery, filter: nil, restrictIDs: nil)
        let coldMs = milliseconds(since: t0)
        XCTAssertEqual(coldIDs.count, Self.totalBooks)

        // 2. fetchAllMatchingIDs (warm - 5 runs, average)
        var warmTimes: [Double] = []
        for _ in 0..<5 {
            let tw = DispatchTime.now()
            _ = await library.fetchAllMatchingIDs(query: emptyQuery, filter: nil, restrictIDs: nil)
            warmTimes.append(milliseconds(since: tw))
        }
        let warmMs = warmTimes.reduce(0, +) / Double(warmTimes.count)

        // 3. fetchAllMatchingIDs (filtered)
        let tf = DispatchTime.now()
        let filteredIDs = await library.fetchAllMatchingIDs(query: filteredQuery, filter: nil, restrictIDs: nil)
        let filteredMs = milliseconds(since: tf)

        // 4. SeriesMatchExpansion.expand
        let te = DispatchTime.now()
        let expandedIDs = await SeriesMatchExpansion.expand(
            matchedIDs: coldIDs,
            shouldGroupSeriesRows: true,
            filter: nil,
            library: library,
            metaDB: nil
        )
        let expandMs = milliseconds(since: te)

        // 5. LibraryVisibilityPolicy.filter
        var policy = LibraryVisibilityPolicy.allowAll
        policy.seriesOrMergedIDs = Set(stride(from: 2, through: Self.totalBooks, by: 4))
        let tv = DispatchTime.now()
        let visibleIDs = policy.filter(expandedIDs)
        let filterMs = milliseconds(since: tv)

        // 6. Bulk dictionary lookup (simulate 100k word counts)
        let syntheticWordCounts = Dictionary(uniqueKeysWithValues: (1...Self.totalBooks).map { ($0, $0 * 150) })
        let tb = DispatchTime.now()
        var retrievedSum = 0
        for id in visibleIDs {
            retrievedSum += syntheticWordCounts[id] ?? 0
        }
        let bulkMs = milliseconds(since: tb)
        _ = retrievedSum

        // 7. Swift in-memory sort (100k items)
        let ts = DispatchTime.now()
        let sortedIDs = visibleIDs.sorted { idA, idB in
            (syntheticWordCounts[idA] ?? 0) > (syntheticWordCounts[idB] ?? 0)
        }
        let sortMs = milliseconds(since: ts)

        // 8. booksForIDs (50 IDs page hydration)
        let pageIDs = Array(sortedIDs.prefix(50))
        let th = DispatchTime.now()
        let hydratedPage = await library.booksForIDs(pageIDs)
        let hydrateMs = milliseconds(since: th)
        XCTAssertEqual(hydratedPage.count, 50)

        let summary = """
        \n================================================================================
        [Pass 0 Benchmark Baseline: \(Self.totalBooks) Books]
        --------------------------------------------------------------------------------
        Operation                                | Timing
        -----------------------------------------+--------------------------------------
        fetchAllMatchingIDs (Cold, Unfiltered)   | \(String(format: "%7.2f ms", coldMs)) (\(coldIDs.count) IDs)
        fetchAllMatchingIDs (Warm, Unfiltered)   | \(String(format: "%7.2f ms", warmMs)) (avg of 5)
        fetchAllMatchingIDs (Filtered "Tag 1")   | \(String(format: "%7.2f ms", filteredMs)) (\(filteredIDs.count) IDs)
        SeriesMatchExpansion.expand              | \(String(format: "%7.2f ms", expandMs))
        LibraryVisibilityPolicy.filter           | \(String(format: "%7.2f ms", filterMs))
        Bulk In-Memory Value Lookup (100k)       | \(String(format: "%7.2f ms", bulkMs))
        Swift Sort (100k items)                  | \(String(format: "%7.2f ms", sortMs))
        booksForIDs (50-item Page Hydration)     | \(String(format: "%7.2f ms", hydrateMs))
        ================================================================================\n
        """
        fputs(summary, stderr)
    }
}
