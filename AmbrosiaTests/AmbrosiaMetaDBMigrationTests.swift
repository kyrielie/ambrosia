import XCTest
import SQLite
@testable import Ambrosia

// Finding 10 (ambrosia_cleanup_plan2.md): running migrations twice on the same
// connection must be a no-op the second time. This is the cheapest, highest-value
// test to have in place before any further schema_migrations changes (Finding 13)
// or filter/paging refactor (plan.md Finding 2) touch this file again.
final class AmbrosiaMetaDBMigrationTests: XCTestCase {

    private func tableNames(_ db: Connection) throws -> Set<String> {
        var names = Set<String>()
        let stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        for row in stmt {
            if let name = row[0] as? String {
                names.insert(name)
            }
        }
        return names
    }

    private func rowCount(_ db: Connection, _ table: String) throws -> Int64 {
        (try db.scalar("SELECT COUNT(*) FROM \(table)")) as? Int64 ?? -1
    }

    func testRunMigrationsTwiceIsANoOp() throws {
        let db = try Connection(.inMemory)

        try AmbrosiaMetaDB.runMigrations(db: db)

        let versionAfterFirst = (try? db.scalar("PRAGMA user_version")) as? Int64 ?? -1
        let tablesAfterFirst = try tableNames(db)
        var rowCountsAfterFirst: [String: Int64] = [:]
        for table in tablesAfterFirst {
            rowCountsAfterFirst[table] = try rowCount(db, table)
        }

        try AmbrosiaMetaDB.runMigrations(db: db)

        let versionAfterSecond = (try? db.scalar("PRAGMA user_version")) as? Int64 ?? -2
        let tablesAfterSecond = try tableNames(db)

        XCTAssertEqual(versionAfterFirst, versionAfterSecond,
                        "PRAGMA user_version must not change on a second migration run")
        XCTAssertEqual(tablesAfterFirst, tablesAfterSecond,
                        "Table set must be identical after a second migration run")
        for table in tablesAfterSecond {
            XCTAssertEqual(
                rowCountsAfterFirst[table], try rowCount(db, table),
                "Row count for \(table) changed on a second migration run"
            )
        }
    }

    func testSchemaMigrationsBridgeIsIdempotent() throws {
        // A fresh database migrates straight to the current schema_migrations
        // rows without ever having gone through the legacy PRAGMA user_version
        // gate, so both named migrations must be recorded as applied exactly
        // once even though createSchemaMigrations/bridgeLegacyUserVersionMigrations
        // and the migrations themselves all run in the same first pass.
        let db = try Connection(.inMemory)
        try AmbrosiaMetaDB.runMigrations(db: db)
        try AmbrosiaMetaDB.runMigrations(db: db)

        let count = (try? db.scalar("SELECT COUNT(*) FROM schema_migrations")) as? Int64 ?? -1
        XCTAssertEqual(count, 2, "Expected exactly the two known migrations recorded, with no duplicates")
    }
}
