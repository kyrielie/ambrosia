import Foundation

/// Pure ordering for the group-aware title sort, split out of
/// `CalibreLibrary.groupAwareTitleSortedPage` so the ordering can be tested
/// without a database.
///
/// Sort key per id: the qualifying series' name if the id belongs to one,
/// otherwise the book's own title, otherwise the empty string. Keys compare
/// with Swift `String` `<` / `>` (not a localized collation). Equal keys fall
/// back to the id, in the sort direction, so the order is total and stable
/// across runs.
enum GroupAwareSorter {
    static func sortKey(for id: Int, seriesNames: [Int: String], titles: [Int: String]) -> String {
        seriesNames[id] ?? titles[id] ?? ""
    }

    /// Computes each key once (instead of two dictionary lookups per
    /// comparison) and sorts `(key, id)` pairs.
    static func sort(ids: [Int], seriesNames: [Int: String], titles: [Int: String],
                     ascending: Bool) -> [Int] {
        var pairs = ids.map { (key: sortKey(for: $0, seriesNames: seriesNames, titles: titles), id: $0) }
        pairs.sort { a, b in
            if a.key == b.key { return ascending ? a.id < b.id : a.id > b.id }
            return ascending ? a.key < b.key : a.key > b.key
        }
        return pairs.map(\.id)
    }
}
