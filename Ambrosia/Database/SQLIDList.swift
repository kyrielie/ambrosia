// SPDX-License-Identifier: GPL-3.0-only
import SQLite

/// Binds a whole id set as ONE parameter instead of one `?` per id.
///
/// Why: once `fulltext:` results are no longer capped (D8), an id set can exceed
/// SQLite's bound-variable limit (`SQLITE_LIMIT_VARIABLE_NUMBER`). A JSON array bound
/// to `json_each` has a single placeholder regardless of the count.
///
/// This is the single seam for gate G7. If `json_each` turns out to be unavailable on
/// Apple's SQLite, change only this file (temp table, or Swift-side chunking); the
/// call sites stay as they are.
enum SQLIDList {

    /// SQL fragment such as `b.id IN (SELECT value FROM json_each(?))`. Contains exactly
    /// one `?`, to be paired with `binding(_:)`.
    static func clause(column: String) -> String {
        "\(column) IN (SELECT value FROM json_each(?))"
    }

    /// The single binding for `clause(column:)`: a JSON array of integers. Ints only, so
    /// a manual join is exact and no encoder is needed.
    static func binding(_ ids: [Int]) -> Binding {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }
}
