import XCTest
@testable import Ambrosia

final class ReadingGoalMathTests: XCTestCase {

    func testZeroTargetReturnsZeroProgressAndPercentage() {
        XCTAssertEqual(ReadingGoal.progress(booksRead: 5, target: 0), 0.0)
        XCTAssertEqual(ReadingGoal.percentage(booksRead: 5, target: 0), 0)
    }

    func testNegativeTargetReturnsZero() {
        XCTAssertEqual(ReadingGoal.progress(booksRead: 5, target: -10), 0.0)
        XCTAssertEqual(ReadingGoal.percentage(booksRead: 5, target: -10), 0)
    }

    func testPartialProgress() {
        let progress = ReadingGoal.progress(booksRead: 5, target: 10)
        XCTAssertEqual(progress, 0.5)
        XCTAssertEqual(ReadingGoal.percentage(booksRead: 5, target: 10), 50)
    }

    func testExceedingTargetClampsProgressToOneAndHundredPercent() {
        let progress = ReadingGoal.progress(booksRead: 15, target: 10)
        XCTAssertEqual(progress, 1.0)
        XCTAssertEqual(ReadingGoal.percentage(booksRead: 15, target: 10), 100)
    }

    func testNegativeBooksReadClampsToZero() {
        let progress = ReadingGoal.progress(booksRead: -2, target: 10)
        XCTAssertEqual(progress, 0.0)
        XCTAssertEqual(ReadingGoal.percentage(booksRead: -2, target: 10), 0)
    }
}
