import XCTest
@testable import Ambrosia

/// Coverage for `DebounceTimer` (`Ambrosia/Utilities/DebounceTimer.swift`).
/// Timing-based (`DispatchWorkItem`/`queue.asyncAfter`), so these use
/// `XCTestExpectation` rather than synchronous assertions, with a short
/// configured delay and an explicit background queue (the `queue:` init
/// param defaults to `.main`, which would need extra ceremony to test from
/// a synchronous XCTest method).
final class DebounceTimerTests: XCTestCase {

    private let delay: TimeInterval = 0.05
    private let queue = DispatchQueue(label: "DebounceTimerTests")

    func testSingleScheduleFiresOnce() {
        let timer = DebounceTimer(delay: delay, queue: queue)
        var fireCount = 0
        let expectation = expectation(description: "fires once")

        timer.schedule {
            fireCount += 1
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(fireCount, 1)
    }

    func testRescheduleBeforeFirstFiresCancelsFirst() {
        let timer = DebounceTimer(delay: delay, queue: queue)
        var firstCount = 0
        var secondCount = 0
        let expectation = expectation(description: "second action fires")

        timer.schedule { firstCount += 1 }
        // Reschedule well before `delay` elapses so the first work item is
        // cancelled before it ever runs.
        queue.asyncAfter(deadline: .now() + delay / 4) {
            timer.schedule {
                secondCount += 1
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(firstCount, 0, "the superseded action must never fire")
        XCTAssertEqual(secondCount, 1)
    }

    func testCancelBeforeDelayElapsedPreventsAction() {
        let timer = DebounceTimer(delay: delay, queue: queue)
        var fired = false

        timer.schedule { fired = true }
        timer.cancel()

        // Wait past the original delay on the same queue to confirm the
        // action never runs, rather than asserting immediately.
        let waited = expectation(description: "waited past original delay")
        queue.asyncAfter(deadline: .now() + delay * 3) {
            waited.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertFalse(fired, "cancel() must prevent the scheduled action from firing")
    }
}
