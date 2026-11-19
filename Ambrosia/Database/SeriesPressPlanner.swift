import Foundation

enum SeriesLikeState: Equatable, Sendable {
    case none
    case partial
    case full
}

enum SeriesPressAction: Equatable, Sendable {
    case clearExclusions
    case clearFlag
    case clearExplicit(Set<Int>)
    case setFlag
}

struct SeriesPressPlan: Equatable, Sendable {
    let actions: [SeriesPressAction]
    let coveringSeriesName: String?
}

enum SeriesPressPlanner {
    static func state(flagIsSet: Bool, exclusions: Set<Int>, memberIDs: Set<Int>, effectiveIDs: Set<Int>) -> SeriesLikeState {
        if flagIsSet { return exclusions.isEmpty ? .full : .partial }
        let effective = memberIDs.intersection(effectiveIDs)
        if effective.isEmpty { return .none }
        return effective.count == memberIDs.count ? .full : .partial
    }

    static func plan(flagIsSet: Bool,
                     exclusions: Set<Int>,
                     displayedMemberIDs: Set<Int>,
                     effectiveIDs: Set<Int>,
                     explicitIDs: Set<Int>,
                     coveringSeriesByMember: [Int: String] = [:]) -> SeriesPressPlan {
        if flagIsSet && !exclusions.isEmpty {
            return SeriesPressPlan(actions: [.clearExclusions], coveringSeriesName: nil)
        }
        if flagIsSet {
            return SeriesPressPlan(actions: [.clearFlag], coveringSeriesName: nil)
        }
        let effectiveMembers = displayedMemberIDs.intersection(effectiveIDs)
        if !displayedMemberIDs.isEmpty && effectiveMembers == displayedMemberIDs {
            let explicitMembers = displayedMemberIDs.intersection(explicitIDs)
            let remainingCover = displayedMemberIDs.subtracting(explicitMembers)
            let coveringName = remainingCover.compactMap { coveringSeriesByMember[$0] }.sorted().first
            return SeriesPressPlan(
                actions: explicitMembers.isEmpty ? [] : [.clearExplicit(explicitMembers)],
                coveringSeriesName: coveringName
            )
        }
        return SeriesPressPlan(actions: [.setFlag], coveringSeriesName: nil)
    }
}
