import Foundation
import SQLite

struct CollectionRow: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String
    var isSystem: Bool
    var createdAt: String
    var sortOrder: Int
}

actor CollectionStore {
    private let db: AmbrosiaMetaDB

    init(db: AmbrosiaMetaDB) {
        self.db = db
    }

    func skip(calibreIDs: [Int]) async throws {
        guard !calibreIDs.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.transaction { db in
            for calibreID in calibreIDs {
                try db.run("INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                           [SystemCollectionID.skipped, calibreID, now])
                try Self.removeWorkFromFlaggedCollection(db: db,
                                                        collectionID: SystemCollectionID.readLater,
                                                        calibreID: calibreID)
            }
        }
    }

    func createCollection(name: String, calibreIDs: [Int] = []) async throws -> CollectionRow {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.run(
            """
            INSERT INTO collections (id, name, kind, is_system, created_at, sort_order)
            VALUES (?, ?, 'manual', 0, ?, ?)
            """,
            [id, name, now, try await nextSortOrder()]
        )
        if !calibreIDs.isEmpty {
            try await bulkAdd(calibreIDs: calibreIDs, to: id)
        }
        return CollectionRow(id: id, name: name, kind: "manual", isSystem: false, createdAt: now, sortOrder: 0)
    }

    func renameCollection(id: String, name: String) async throws {
        try await db.run(
            "UPDATE collections SET name = ? WHERE id = ? AND is_system = 0",
            [name, id]
        )
    }

    func deleteCollection(id: String) async throws {
        try await db.transaction { db in
            try db.run("DELETE FROM collection_members WHERE collection_id = ?", [id])
            try db.run("DELETE FROM collections WHERE id = ? AND is_system = 0", [id])
        }
    }

    func remove(calibreID: Int, from collectionID: String) async throws {
        try await db.run(
            "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
            [collectionID, calibreID]
        )
    }

    func bulkRemove(calibreIDs: [Int], from collectionID: String) async throws {
        guard !calibreIDs.isEmpty else { return }
        try await db.transaction { db in
            for id in calibreIDs {
                try db.run(
                    "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
                    [collectionID, id]
                )
            }
        }
    }

    func toggle(calibreID: Int, in collectionID: String) async throws {
        if try await isMember(calibreID: calibreID, of: collectionID) {
            try await remove(calibreID: calibreID, from: collectionID)
        } else {
            try await bulkAdd(calibreIDs: [calibreID], to: collectionID)
        }
    }

    func toggleLiked(calibreID: Int) async throws {
        try await toggle(calibreID: calibreID, in: SystemCollectionID.liked)
    }

    func setLiked(calibreIDs: [Int], liked: Bool) async throws {
        if liked {
            try await bulkAdd(calibreIDs: calibreIDs, to: SystemCollectionID.liked)
        } else {
            try await bulkRemove(calibreIDs: calibreIDs, from: SystemCollectionID.liked)
        }
    }

    func setLiked(states: [Int: Bool]) async throws {
        try await setMembershipStates(states, in: SystemCollectionID.liked)
    }

    func setReadLater(calibreIDs: [Int], inReadLater: Bool) async throws {
        if inReadLater {
            try await bulkAdd(calibreIDs: calibreIDs, to: SystemCollectionID.readLater)
        } else {
            try await bulkRemove(calibreIDs: calibreIDs, from: SystemCollectionID.readLater)
        }
    }

    func setReadLater(states: [Int: Bool]) async throws {
        try await setMembershipStates(states, in: SystemCollectionID.readLater)
    }

    @discardableResult
    func setWorkFlags(collectionID: String, desired: [Int: Bool]) async throws -> MembershipDelta {
        let IDs = Array(desired.keys)
        guard !IDs.isEmpty else { return MembershipDelta(current: [], computed: []) }
        let before = try await effectiveMembers(collectionID: collectionID, IDs: IDs)
        let desiredIDs = Set(desired.compactMap { $0.value ? $0.key : nil })
        if try await db.hasSeriesFlags() == false {
            let states = Dictionary(uniqueKeysWithValues: desired.map { ($0.key, $0.value) })
            try await setMembershipStates(states, in: collectionID)
        } else {
            try await db.transaction { db in
                for (calibreID, shouldBeMember) in desired {
                    let currentlyMember = before.contains(calibreID)
                    guard currentlyMember != shouldBeMember else { continue }
                    if shouldBeMember {
                        try db.run("INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                                   [collectionID, calibreID, ISO8601DateFormatter().string(from: Date())])
                    } else {
                        try Self.removeWorkFromFlaggedCollection(db: db, collectionID: collectionID, calibreID: calibreID)
                    }
                }
            }
        }
        let after = try await effectiveMembers(collectionID: collectionID, IDs: IDs)
        _ = desiredIDs
        return MembershipDelta(current: before, computed: after)
    }

    func seriesFlagSnapshot(collectionID: String) async throws -> [Int: SeriesCollectionFlag] {
        let rows = try await db.prepare("""
            SELECT f.series_id, s.name, m.calibre_id, x.calibre_id
            FROM series_collection_members f
            JOIN series s ON s.series_id = f.series_id
            LEFT JOIN series_cache m ON m.series_id = f.series_id
            LEFT JOIN series_collection_exclusions x
              ON x.collection_id = f.collection_id AND x.series_id = f.series_id
             AND x.calibre_id = m.calibre_id
            WHERE f.collection_id = ?
            ORDER BY f.series_id, x.calibre_id
            """, [collectionID])
        var members: [Int: Set<Int>] = [:]
        var exclusions: [Int: Set<Int>] = [:]
        var names: [Int: String] = [:]
        for row in rows {
            guard let seriesID = (row[safe: 0] as? Int64).map(Int.init) ?? (row[safe: 0] as? Int) else { continue }
            let seriesName = row[safe: 1] as? String ?? ""
            if let memberID = (row[safe: 2] as? Int64).map(Int.init) ?? (row[safe: 2] as? Int) {
                members[seriesID, default: []].insert(memberID)
            }
            exclusions[seriesID, default: []].formUnion(
                [(row[safe: 3] as? Int64).map(Int.init) ?? (row[safe: 3] as? Int)].compactMap { $0 }
            )
            names[seriesID] = seriesName
        }
        return Dictionary(uniqueKeysWithValues: exclusions.map { entry in
            let id = entry.key
            return (id, SeriesCollectionFlag(seriesID: id, seriesName: names[id] ?? "",
                                             memberIDs: members[id] ?? [], exclusions: entry.value))
        })
    }

    @discardableResult
    func applySeriesActions(collectionID: String, seriesID: Int, actions: [SeriesPressAction]) async throws -> MembershipDelta {
        guard !actions.isEmpty else { return MembershipDelta(current: [], computed: []) }
        var affectedIDs = Set<Int>()
        for action in actions {
            switch action {
            case .clearExclusions, .clearFlag, .setFlag:
                let rows = try await db.prepare("SELECT calibre_id FROM series_cache WHERE series_id = ?", [seriesID])
                affectedIDs.formUnion(rows.compactMap { ($0[safe: 0] as? Int64).map(Int.init) ?? ($0[safe: 0] as? Int) })
            case .clearExplicit(let ids): affectedIDs.formUnion(ids)
            }
        }
        let before = try await effectiveMembers(collectionID: collectionID, IDs: Array(affectedIDs))
        try await db.transaction { db in
            for action in actions {
                switch action {
                case .clearExclusions:
                    try db.run("DELETE FROM series_collection_exclusions WHERE collection_id = ? AND series_id = ?", [collectionID, seriesID])
                case .clearFlag:
                    try db.run("DELETE FROM series_collection_members WHERE collection_id = ? AND series_id = ?", [collectionID, seriesID])
                case .clearExplicit(let ids):
                    for id in ids {
                        try db.run("DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?", [collectionID, id])
                    }
                case .setFlag:
                    let query = """
                        SELECT COUNT(*) FROM series
                        WHERE series_id = ? AND (ao3_series_id IS NOT NULL OR calibre_series_id IS NOT NULL)
                        """
                    let eligible = (try db.scalar(query, [seriesID]) as? Int64) ?? 0
                    guard eligible > 0 else {
                        throw NSError(domain: "CollectionStore", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Name-only series cannot be flagged"])
                    }
                    try db.run("INSERT OR IGNORE INTO series_collection_members (collection_id, series_id, added_at) VALUES (?, ?, ?)",
                               [collectionID, seriesID, ISO8601DateFormatter().string(from: Date())])
                }
            }
        }
        await db.invalidateSeriesFlagsCache()
        let after = try await effectiveMembers(collectionID: collectionID, IDs: Array(affectedIDs))
        return MembershipDelta(current: before, computed: after)
    }

    private func setMembershipStates(_ states: [Int: Bool], in collectionID: String) async throws {
        let adding = states.compactMap { $0.value ? $0.key : nil }.sorted()
        let removing = states.compactMap { $0.value ? nil : $0.key }.sorted()
        guard !adding.isEmpty || !removing.isEmpty else { return }
        let addedAt = ISO8601DateFormatter().string(from: Date())
        try await db.transaction { db in
            for calibreID in removing {
                try db.run(
                    "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
                    [collectionID, calibreID]
                )
            }
            for calibreID in adding {
                try db.run(
                    "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                    [collectionID, calibreID, addedAt]
                )
            }
        }
    }

    func bulkAdd(calibreIDs: [Int], to collectionID: String) async throws {
        guard !calibreIDs.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.transaction { db in
            for id in calibreIDs {
                try db.run(
                    "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                    [collectionID, id, now]
                )
            }
        }
    }

    func replaceMembers(of collectionID: String, with calibreIDs: Set<Int>) async throws {
        let sortedIDs = Array(calibreIDs).sorted()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.transaction { db in
            try db.run(
                "DELETE FROM collection_members WHERE collection_id = ?",
                [collectionID]
            )
            for id in sortedIDs {
                try db.run(
                    "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                    [collectionID, id, now]
                )
            }
        }
    }

    /// Applies a membership change as removals plus additions in one
    /// transaction, leaving every other row (and its `added_at`) untouched.
    /// Use instead of `replaceMembers` when the caller already knows the
    /// difference, so an unchanged 40k-row collection is not deleted and
    /// re-inserted. A no-op delta does not open a transaction.
    func applyMemberDelta(of collectionID: String, adding: [Int], removing: [Int]) async throws {
        guard !adding.isEmpty || !removing.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.transaction { db in
            for id in removing {
                try db.run(
                    "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
                    [collectionID, id]
                )
            }
            for id in adding {
                try db.run(
                    "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                    [collectionID, id, now]
                )
            }
        }
    }

    func syncAutomatedCollection(collectionID: String, calibreID: Int, shouldBeMember: Bool) async throws {
        if shouldBeMember {
            try await db.run(
                "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                [collectionID, calibreID, ISO8601DateFormatter().string(from: Date())]
            )
        } else {
            try await db.run(
                "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
                [collectionID, calibreID]
            )
        }
    }

    func members(of collectionID: String) async throws -> [Int] {
        let hasFlags = try await db.hasSeriesFlags()
        let readSignpost = LaunchSignposts.begin(hasFlags ? "collection.read.effectiveView" : "collection.read.explicitRows")
        defer { LaunchSignposts.end(hasFlags ? "collection.read.effectiveView" : "collection.read.explicitRows", readSignpost) }
        let source = hasFlags ? "effective_collection_members" : "collection_members"
        let rows = try await db.prepare(
            "SELECT calibre_id FROM \(source) WHERE collection_id = ? ORDER BY added_at, calibre_id ASC",
            [collectionID]
        )
        return rows.compactMap { row in
            if let id = row[safe: 0] as? Int64 { return Int(id) }
            return row[safe: 0] as? Int
        }
    }

    func memberAddedDates(for collectionID: String) async throws -> [Int: Date] {
        let iso = ISO8601DateFormatter()
        let hasFlags = try await db.hasSeriesFlags()
        let readSignpost = LaunchSignposts.begin(hasFlags ? "collection.dates.effectiveView" : "collection.dates.explicitRows")
        defer { LaunchSignposts.end(hasFlags ? "collection.dates.effectiveView" : "collection.dates.explicitRows", readSignpost) }
        let sql = hasFlags
            ? "SELECT calibre_id, MIN(added_at) FROM effective_collection_members WHERE collection_id = ? GROUP BY calibre_id"
            : "SELECT calibre_id, added_at FROM collection_members WHERE collection_id = ?"
        let rows = try await db.prepare(
            sql,
            [collectionID]
        )
        return rows.reduce(into: [Int: Date]()) { dict, row in
            guard let id = (row[safe: 0] as? Int64).map(Int.init) ?? (row[safe: 0] as? Int),
                  let dateStr = row[safe: 1] as? String else { return }
            dict[id] = iso.date(from: dateStr)
        }
    }

    func collections() async throws -> [CollectionRow] {
        let rows = try await db.prepare(
            """
            SELECT id, name, kind, is_system, created_at, sort_order
            FROM collections
            ORDER BY sort_order, name
            """
        )
        return rows.compactMap { row in
            guard let id = row[safe: 0] as? String,
                  let name = row[safe: 1] as? String,
                  let kind = row[safe: 2] as? String,
                  let createdAt = row[safe: 4] as? String else { return nil }
            let systemValue = (row[safe: 3] as? Int64).map(Int.init) ?? (row[safe: 3] as? Int) ?? 0
            let sortOrder = (row[safe: 5] as? Int64).map(Int.init) ?? (row[safe: 5] as? Int) ?? 0
            return CollectionRow(
                id: id,
                name: name,
                kind: kind,
                isSystem: systemValue != 0,
                createdAt: createdAt,
                sortOrder: sortOrder
            )
        }
    }

    func membershipMap() async throws -> [String: Set<Int>] {
        let hasFlags = try await db.hasSeriesFlags()
        let readSignpost = LaunchSignposts.begin(hasFlags ? "collection.map.effectiveView" : "collection.map.explicitRows")
        defer { LaunchSignposts.end(hasFlags ? "collection.map.effectiveView" : "collection.map.explicitRows", readSignpost) }
        let source = hasFlags ? "effective_collection_members" : "collection_members"
        let rows = try await db.prepare(
            """
            SELECT c.name, cm.calibre_id
            FROM collections c
            JOIN \(source) cm ON cm.collection_id = c.id
            ORDER BY c.name
            """
        )
        return rows.reduce(into: [String: Set<Int>]()) { partial, row in
            guard let name = row[safe: 0] as? String else { return }
            let id = (row[safe: 1] as? Int64).map(Int.init) ?? (row[safe: 1] as? Int)
            guard let id else { return }
            partial[name, default: []].insert(id)
        }
    }

    func membershipByCollectionID() async throws -> [String: Set<Int>] {
        let hasFlags = try await db.hasSeriesFlags()
        let readSignpost = LaunchSignposts.begin(hasFlags ? "collection.byID.effectiveView" : "collection.byID.explicitRows")
        defer { LaunchSignposts.end(hasFlags ? "collection.byID.effectiveView" : "collection.byID.explicitRows", readSignpost) }
        let source = hasFlags ? "effective_collection_members" : "collection_members"
        let rows = try await db.prepare(
            """
            SELECT collection_id, calibre_id
            FROM \(source)
            ORDER BY collection_id
            """
        )
        return rows.reduce(into: [String: Set<Int>]()) { partial, row in
            guard let id = row[safe: 0] as? String else { return }
            let calibreID = (row[safe: 1] as? Int64).map(Int.init) ?? (row[safe: 1] as? Int)
            guard let calibreID else { return }
            partial[id, default: []].insert(calibreID)
        }
    }

    func likedIDs() async throws -> Set<Int> {
        Set(try await members(of: SystemCollectionID.liked))
    }

    func explicitMembers(of collectionID: String) async throws -> [Int] {
        let rows = try await db.prepare(
            "SELECT calibre_id FROM collection_members WHERE collection_id = ? ORDER BY added_at, calibre_id ASC",
            [collectionID]
        )
        return rows.compactMap { row in
            if let id = row[safe: 0] as? Int64 { return Int(id) }
            return row[safe: 0] as? Int
        }
    }

    func isMember(calibreID: Int, of collectionID: String) async throws -> Bool {
        let count = try await db.scalar(
            "SELECT COUNT(*) FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
            [collectionID, calibreID]
        )
        if let value = count as? Int64 { return value > 0 }
        if let value = count as? Int { return value > 0 }
        return false
    }

    private func nextSortOrder() async throws -> Int {
        let value = try await db.scalar("SELECT COALESCE(MAX(sort_order), 0) + 1 FROM collections")
        return (value as? Int64).map(Int.init) ?? (value as? Int) ?? 0
    }

    private func effectiveMembers(collectionID: String, IDs: [Int]) async throws -> Set<Int> {
        guard !IDs.isEmpty else { return [] }
        let source = try await db.hasSeriesFlags() ? "effective_collection_members" : "collection_members"
        let clause = SQLIDList.clause(column: "calibre_id")
        let rows = try await db.prepare(
            "SELECT calibre_id FROM \(source) WHERE collection_id = ? AND \(clause)",
            [collectionID, SQLIDList.binding(IDs)]
        )
        return Set(rows.compactMap { ($0[safe: 0] as? Int64).map(Int.init) ?? ($0[safe: 0] as? Int) })
    }

    private static func removeWorkFromFlaggedCollection(db: isolated AmbrosiaMetaDB,
                                                        collectionID: String,
                                                        calibreID: Int) throws {
        try db.run("DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
                   [collectionID, calibreID])
        try db.run("""
            INSERT OR IGNORE INTO series_collection_exclusions (collection_id, series_id, calibre_id)
            SELECT f.collection_id, f.series_id, ?
            FROM series_collection_members f
            JOIN series_cache m ON m.series_id = f.series_id
            WHERE f.collection_id = ? AND m.calibre_id = ?
            """, [calibreID, collectionID, calibreID])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
