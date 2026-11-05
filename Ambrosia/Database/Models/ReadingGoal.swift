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

public struct FandomInsight: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let words: Int
    public let works: Int

    public init(name: String, words: Int, works: Int) {
        self.name = name
        self.words = words
        self.works = works
    }
}

public struct RelationshipInsight: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let words: Int
    public let works: Int
    public let isRomantic: Bool

    public init(name: String, words: Int, works: Int, isRomantic: Bool) {
        self.name = name
        self.words = words
        self.works = works
        self.isRomantic = isRomantic
    }
}

public struct TagInsight: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let words: Int
    public let works: Int

    public init(name: String, words: Int, works: Int) {
        self.name = name
        self.words = words
        self.works = works
    }
}

public struct ReadingStatsInsights: Sendable, Equatable {
    public let topFandoms: [FandomInsight]
    public let topRelationships: [RelationshipInsight]
    public let topTags: [TagInsight]
    public let totalWords: Int
    public let totalWorks: Int
    public let wordsPerHour: Double
    public let activeSeconds: Double

    public init(
        topFandoms: [FandomInsight] = [],
        topRelationships: [RelationshipInsight] = [],
        topTags: [TagInsight] = [],
        totalWords: Int = 0,
        totalWorks: Int = 0,
        wordsPerHour: Double = 0.0,
        activeSeconds: Double = 0.0
    ) {
        self.topFandoms = topFandoms
        self.topRelationships = topRelationships
        self.topTags = topTags
        self.totalWords = totalWords
        self.totalWorks = totalWorks
        self.wordsPerHour = wordsPerHour
        self.activeSeconds = activeSeconds
    }
}
