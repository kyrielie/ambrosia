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
    /// Merged anthologies (`anthologyIDs`) are excluded from competing as
    /// single-work duplicates so they are never hidden behind or conflated with
    /// an individual work sharing Work #1's `ao3_work_id`.
    ///
    /// Winner selection: prefer the newer `updated` date; if either/both are
    /// missing, fall back to the newer `published` date; on ties, prefer higher
    /// `chapterCurrent`, higher `wordCount`, newer `dateAdded`, and finally the
    /// lower `calibre_id` so the choice is stable across reloads.
    static func loserIDs(
        workIDs: [Int: String],
        dates: [Int: (published: String?, updated: String?)],
        anthologyIDs: Set<Int> = [],
        wordCounts: [Int: Int] = [:],
        chapterCurrents: [Int: Int] = [:],
        datesAdded: [Int: Date] = [:]
    ) -> Set<Int> {
        guard !workIDs.isEmpty else { return [] }

        let groups = Dictionary(grouping: workIDs.keys, by: { workIDs[$0] ?? "" })
        var losers = Set<Int>()

        for (_, calibreIDs) in groups where calibreIDs.count > 1 {
            let standaloneIDs = anthologyIDs.isEmpty ? calibreIDs : calibreIDs.filter { !anthologyIDs.contains($0) }
            guard standaloneIDs.count > 1 else { continue }
            if let winner = preferredWinner(
                in: standaloneIDs,
                dates: dates,
                wordCounts: wordCounts,
                chapterCurrents: chapterCurrents,
                datesAdded: datesAdded
            ) {
                losers.formUnion(standaloneIDs.filter { $0 != winner })
            }
        }

        return losers
    }

    /// Selects the single preferred winner among a list of duplicate calibre IDs.
    static func preferredWinner(
        in calibreIDs: [Int],
        dates: [Int: (published: String?, updated: String?)],
        wordCounts: [Int: Int] = [:],
        chapterCurrents: [Int: Int] = [:],
        datesAdded: [Int: Date] = [:]
    ) -> Int? {
        guard let first = calibreIDs.first else { return nil }
        return calibreIDs.dropFirst().reduce(first) { current, candidate in
            isPreferred(
                candidate,
                over: current,
                dates: dates,
                wordCounts: wordCounts,
                chapterCurrents: chapterCurrents,
                datesAdded: datesAdded
            ) ? candidate : current
        }
    }

    /// True if `candidate` should be kept over `current` as the winner of
    /// their duplicate group.
    static func isPreferred(
        _ candidate: Int,
        over current: Int,
        dates: [Int: (published: String?, updated: String?)],
        wordCounts: [Int: Int] = [:],
        chapterCurrents: [Int: Int] = [:],
        datesAdded: [Int: Date] = [:]
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

        let candidateChapters = chapterCurrents[candidate] ?? 0
        let currentChapters = chapterCurrents[current] ?? 0
        if candidateChapters != currentChapters {
            return candidateChapters > currentChapters
        }

        let candidateWords = wordCounts[candidate] ?? 0
        let currentWords = wordCounts[current] ?? 0
        if candidateWords != currentWords {
            return candidateWords > currentWords
        }

        if let candidateAdded = datesAdded[candidate], let currentAdded = datesAdded[current], candidateAdded != currentAdded {
            return candidateAdded > currentAdded
        }

        // No usable dates/counts on either side, or an exact tie: stable arbitrary
        // tiebreak so the winner never flip-flops across refreshes.
        return candidate < current
    }
}
