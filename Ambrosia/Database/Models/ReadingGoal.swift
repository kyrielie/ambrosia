import Foundation

public struct ReadingGoal: Identifiable, Sendable, Equatable, Hashable {
    public var id: Int64
    public var targetBooksCount: Int
    public var periodStart: Date
    public var periodEnd: Date

    public init(
        id: Int64 = 0,
        targetBooksCount: Int,
        periodStart: Date,
        periodEnd: Date
    ) {
        self.id = id
        self.targetBooksCount = targetBooksCount
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}
