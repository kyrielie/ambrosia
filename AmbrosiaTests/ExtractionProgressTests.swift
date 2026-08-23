import XCTest
@testable import Ambrosia

/// Coverage for `ExtractionProgress` (`Ambrosia/Database/ExtractionProgress.swift`).
/// `@Observable` but otherwise trivial: no singleton, no UserDefaults, plain
/// stored properties plus one computed property.
final class ExtractionProgressTests: XCTestCase {

    func testStatusTextNilWhenNotRunningRegardlessOfCompletedTotal() {
        let progress = ExtractionProgress()
        progress.isRunning = false
        progress.completed = 5
        progress.total = 10
        XCTAssertNil(progress.statusText)

        progress.completed = 0
        progress.total = 0
        XCTAssertNil(progress.statusText)
    }

    func testStatusTextShowsCountsWhenRunningWithPositiveTotal() {
        let progress = ExtractionProgress()
        progress.isRunning = true
        progress.completed = 3
        progress.total = 20
        XCTAssertEqual(progress.statusText, "Enriching library 3/20")
    }

    func testStatusTextShowsEllipsisWhenRunningWithZeroTotal() {
        let progress = ExtractionProgress()
        progress.isRunning = true
        progress.completed = 0
        progress.total = 0
        XCTAssertEqual(progress.statusText, "Enriching library…")
    }

    func testDefaultsAreZeroAndNotRunning() {
        let progress = ExtractionProgress()
        XCTAssertEqual(progress.completed, 0)
        XCTAssertEqual(progress.total, 0)
        XCTAssertFalse(progress.isRunning)
        XCTAssertNil(progress.statusText)
    }
}
