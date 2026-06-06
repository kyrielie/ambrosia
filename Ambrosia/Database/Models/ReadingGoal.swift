import SwiftData
import Foundation

@Model
final class ReadingGoal {
    var targetBooksCount: Int
    var periodStart: Date
    var periodEnd: Date

    init(targetBooksCount: Int, periodStart: Date, periodEnd: Date) {
        self.targetBooksCount = targetBooksCount
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}
