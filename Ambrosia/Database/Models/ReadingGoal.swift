import SwiftData
import Foundation

// Phase 0 stub
@Model
final class ReadingGoal {
    var targetBooksCount: Int = 0
    var periodStart: Date = Date()
    var periodEnd: Date = Date()

    init(targetBooksCount: Int, periodStart: Date, periodEnd: Date) {
        self.targetBooksCount = targetBooksCount
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}
