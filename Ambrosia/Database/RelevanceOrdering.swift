import Foundation

// MARK: - TagPosition

/// The 0-based array index and role priority of a matched tag within `ao3_metadata`.
struct TagPosition: Comparable, Equatable {
    /// Priority ordering across tag roles:
    /// 0: relationship (first-listed relationship)
    /// 1: character (first-listed character)
    /// 2: fandom
    /// 3: freeform (additional tags)
    let roleRank: Int

    /// 0-based array index in the author's tag list.
    let index: Int

    static func < (lhs: TagPosition, rhs: TagPosition) -> Bool {
        if lhs.roleRank != rhs.roleRank {
            return lhs.roleRank < rhs.roleRank
        }
        return lhs.index < rhs.index
    }
}

// MARK: - RelevanceOrdering

enum RelevanceOrdering {
    /// Pure comparator for relevance sorting.
    ///
    /// - When `rankMap` is present (FTS / semantic search active):
    ///   1. Candidate rank (text relevance strictly beats tag position; position is a tie-breaker).
    ///   2. Tag position (`TagPosition` ascending: roleRank, then index).
    ///   3. Tie-breaker (custom closure or deterministic book ID `idA < idB`).
    ///
    /// - When `rankMap` is nil (tag-only filter or untyped search):
    ///   1. Tag position (`TagPosition` ascending: lowest roleRank, lowest index).
    ///   2. Unmatched books (nil position) sort last.
    ///   3. Tie-breaker (custom closure or deterministic book ID `idA < idB`).
    ///
    /// - `ascending`: Inverts the primary ordering if true (relevance normally defaults to descending, i.e. ascending == false).
    static func areInIncreasingOrder(
        idA: Int,
        idB: Int,
        rankMap: [Int: Int]?,
        posMap: [Int: TagPosition]?,
        ascending: Bool,
        tieBreak: ((Int, Int) -> Bool)? = nil
    ) -> Bool {
        let fallback = { tieBreak?(idA, idB) ?? (idA < idB) }
        if let rankMap {
            let rankA = rankMap[idA]
            let rankB = rankMap[idB]
            switch (rankA, rankB) {
            case let (valA?, valB?):
                if valA != valB {
                    return ascending ? valA > valB : valA < valB
                }
                // Tie-breaker: tag position
                let posA = posMap?[idA]
                let posB = posMap?[idB]
                switch (posA, posB) {
                case let (pA?, pB?):
                    if pA != pB {
                        return pA < pB
                    }
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }
                return fallback()
            case (.some, nil):
                return !ascending
            case (nil, .some):
                return ascending
            case (nil, nil):
                return fallback()
            }
        }

        // Tag-only / no text rank map
        let posA = posMap?[idA]
        let posB = posMap?[idB]
        switch (posA, posB) {
        case let (pA?, pB?):
            if pA != pB {
                return ascending ? pA > pB : pA < pB
            }
            return fallback()
        case (.some, nil):
            return !ascending
        case (nil, .some):
            return ascending
        case (nil, nil):
            return fallback()
        }
    }
}
