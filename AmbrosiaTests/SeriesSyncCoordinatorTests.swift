import XCTest
@testable import Ambrosia

final class SeriesSyncCoordinatorTests: XCTestCase {

    func testSingleExpectedCompletionFires() {
        var c = SeriesSyncCoordinator()
        let gen = c.begin(awaiting: 1)
        XCTAssertTrue(c.complete(generation: gen))
    }

    func testOnlyTheLastOfTwoCompletionsFires() {
        var c = SeriesSyncCoordinator()
        let gen = c.begin(awaiting: 2)
        XCTAssertFalse(c.complete(generation: gen))
        XCTAssertTrue(c.complete(generation: gen))
    }

    func testExtraCompletionAfterZeroDoesNotFireAgain() {
        // The open sequence awaits only the series seed; an extra completion
        // (for example a late extraction callback) must never trigger a second sync.
        var c = SeriesSyncCoordinator()
        let gen = c.begin(awaiting: 1)
        XCTAssertTrue(c.complete(generation: gen))
        XCTAssertFalse(c.complete(generation: gen))
    }

    func testSupersededGenerationNeverFiresAndDoesNotCount() {
        var c = SeriesSyncCoordinator()
        let old = c.begin(awaiting: 1)
        let new = c.begin(awaiting: 1)
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(c.isCurrent(old))
        XCTAssertTrue(c.isCurrent(new))
        XCTAssertFalse(c.complete(generation: old))
        // The stale completion must not have consumed the new batch's count.
        XCTAssertTrue(c.complete(generation: new))
    }

    func testCompletionWithoutABatchDoesNothing() {
        var c = SeriesSyncCoordinator()
        XCTAssertFalse(c.complete(generation: 0))
    }

    func testZeroCountBatchNeverFires() {
        var c = SeriesSyncCoordinator()
        let gen = c.begin(awaiting: 0)
        XCTAssertFalse(c.complete(generation: gen))
    }
}
