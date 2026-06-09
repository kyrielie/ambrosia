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

    func skipBook(calibreID: Int) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.run(
            "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
            [SystemCollectionID.skipped, calibreID, now]
        )
        try await db.run(
            "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
            [SystemCollectionID.readLater, calibreID]
        )
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
        try await db.run("DELETE FROM collections WHERE id = ? AND is_system = 0", [id])
    }

    func remove(calibreID: Int, from collectionID: String) async throws {
        try await db.run(
            "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
            [collectionID, calibreID]
        )
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

    func bulkAdd(calibreIDs: [Int], to collectionID: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        for id in calibreIDs {
            try await db.run(
                "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
                [collectionID, id, now]
            )
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
        let rows = try await db.prepare(
            "SELECT calibre_id FROM collection_members WHERE collection_id = ? ORDER BY added_at",
            [collectionID]
        )
        return rows.compactMap { row in
            if let id = row[safe: 0] as? Int64 { return Int(id) }
            return row[safe: 0] as? Int
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
        let rows = try await db.prepare(
            """
            SELECT c.name, cm.calibre_id
            FROM collections c
            JOIN collection_members cm ON cm.collection_id = c.id
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
        let rows = try await db.prepare(
            """
            SELECT collection_id, calibre_id
            FROM collection_members
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
