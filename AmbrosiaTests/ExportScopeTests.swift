import XCTest
@testable import Ambrosia

// Covers ExportManager.exportScope(for:), the pure derivation behind
// buildExportRows. The regression: an empty explicit-ID filter result (for
// example a zero-hit fulltext search) used to collapse to "no restriction"
// and export the whole library.
final class ExportScopeTests: XCTestCase {

    func testNilResultIsUnrestricted() {
        XCTAssertEqual(ExportManager.exportScope(for: nil), .unrestricted)
    }

    func testEmptyExplicitResultIsEmpty() {
        let result = FilterResult(calibreIDs: [], totalCount: 0, isSQLBacked: false)
        XCTAssertEqual(ExportManager.exportScope(for: result), .empty)
    }

    func testNonEmptyExplicitResultIsIDs() {
        let result = FilterResult(calibreIDs: [3, 5, 8])
        XCTAssertEqual(ExportManager.exportScope(for: result), .ids([3, 5, 8]))
    }

    func testSQLBackedResultIsSQLFilterEvenWithEmptyIDs() {
        let result = FilterResult(calibreIDs: [], isSQLBacked: true)
        XCTAssertEqual(ExportManager.exportScope(for: result), .sqlFilter)
    }
}
