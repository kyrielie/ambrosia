import Foundation

/// Identifies stale Calibre duplicates of the same AO3 work.
///
/// A Calibre library can end up with two rows (two distinct `calibre_id`s)
/// for the same AO3 work — e.g. a re-download/re-import. This type groups
/// calibre IDs by `ao3_work_id` (the only reliable identity key here — title/
/// author matching is not used) and, for any group with more than one member,
/// picks a single winner to keep. Every other member of the group is a
/// "loser" and is reported back for the caller to hide.
///
/// Books with no extracted AO3 metadata (`ao3_work_id == nil`) never
/// participate — they can't be identified as duplicates by this mechanism.
///
/// Pure value type: no actor isolation, no shared mutable state, safe to
/// call from anywhere with the two cached dictionaries already maintained by
/// `CalibreLibrary` (`ao3WorkIDCache`, `ao3DateCache`).
enum DuplicateBookDetector {

    /// Returns the calibre IDs that should be hidden as stale duplicates —
    /// every ID in a shared-`ao3_work_id` group except the winner.
    ///
    /// Winner selection: prefer the newer `updated` date; if either/both are
    /// missing, fall back to the newer `published` date; if dates are equal
    /// or entirely absent on both sides, fall back to the lower `calibre_id`
    /// so the choice is arbitrary but stable across reloads (the same pair
    /// always resolves the same way, so the "winner" doesn't flip-flop
    /// between library refreshes).
    static func loserIDs(
        workIDs: [Int: String],
        dates: [Int: (published: String?, updated: String?)]
    ) -> Set<Int> {
        guard !workIDs.isEmpty else { return [] }

        let groups = Dictionary(grouping: workIDs.keys, by: { workIDs[$0]! })
        var losers = Set<Int>()

        for (_, calibreIDs) in groups where calibreIDs.count > 1 {
            let winner = calibreIDs.dropFirst().reduce(calibreIDs[calibreIDs.startIndex]) { current, candidate in
                isPreferred(candidate, over: current, dates: dates) ? candidate : current
            }
            losers.formUnion(calibreIDs.filter { $0 != winner })
        }

        return losers
    }

    /// True if `candidate` should be kept over `current` as the winner of
    /// their duplicate group.
    private static func isPreferred(
        _ candidate: Int,
        over current: Int,
        dates: [Int: (published: String?, updated: String?)]
    ) -> Bool {
        let candidateUpdated = parseISODate(dates[candidate]?.updated)
        let currentUpdated = parseISODate(dates[current]?.updated)
        if let candidateUpdated, let currentUpdated, candidateUpdated != currentUpdated {
            return candidateUpdated > currentUpdated
        }
        if candidateUpdated != nil, currentUpdated == nil { return true }
        if currentUpdated != nil, candidateUpdated == nil { return false }

        let candidatePublished = parseISODate(dates[candidate]?.published)
        let currentPublished = parseISODate(dates[current]?.published)
        if let candidatePublished, let currentPublished, candidatePublished != currentPublished {
            return candidatePublished > currentPublished
        }
        if candidatePublished != nil, currentPublished == nil { return true }
        if currentPublished != nil, candidatePublished == nil { return false }

        // No usable dates on either side, or an exact tie: stable arbitrary
        // tiebreak so the winner never flip-flops across refreshes.
        return candidate < current
    }
}
