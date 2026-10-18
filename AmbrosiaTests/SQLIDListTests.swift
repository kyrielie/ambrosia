// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SQLite
@testable import Ambrosia

final class SQLIDListTests: XCTestCase {

    private func makeTable(rowCount: Int) throws -> Connection {
        let conn = try Connection(.inMemory)
        try conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        try conn.transaction {
            for rowID in 1...rowCount {
                try conn.run("INSERT INTO t (id, v) VALUES (?, 'x')", rowID)
            }
        }
        return conn
    }

    private func select(_ conn: Connection, ids: [Int]) throws -> [Int] {
        let sql = "SELECT id FROM t WHERE \(SQLIDList.clause(column: "id")) ORDER BY id"
        return try conn.prepare(sql, [SQLIDList.binding(ids)]).compactMap { ($0[0] as? Int64).map(Int.init) }
    }

    func testClauseHasExactlyOnePlaceholder() {
        let clause = SQLIDList.clause(column: "b.id")
        XCTAssertEqual(clause.filter { $0 == "?" }.count, 1)
        XCTAssertTrue(clause.hasPrefix("b.id IN"))
    }

    func testBindingIsJSONArrayRegardlessOfCount() {
        XCTAssertEqual(SQLIDList.binding([]) as? String, "[]")
        XCTAssertEqual(SQLIDList.binding([7]) as? String, "[7]")
        XCTAssertEqual(SQLIDList.binding([3, 1, 2]) as? String, "[3,1,2]")
    }

    func testFortyThousandIDsReturnExactlyTheMatchingRows() throws {
        // Above any plausible SQLITE_LIMIT_VARIABLE_NUMBER (default 32766 since 3.32).
        let conn = try makeTable(rowCount: 50_000)
        let ids = Array(1...40_000)
        let got = try select(conn, ids: ids)
        XCTAssertEqual(got.count, 40_000)
        XCTAssertEqual(got.first, 1)
        XCTAssertEqual(got.last, 40_000)
    }

    func testEmptyListMatchesNothing() throws {
        let conn = try makeTable(rowCount: 5)
        XCTAssertEqual(try select(conn, ids: []), [])
    }

    func testSingleIDAndDuplicates() throws {
        let conn = try makeTable(rowCount: 5)
        XCTAssertEqual(try select(conn, ids: [3]), [3])
        XCTAssertEqual(try select(conn, ids: [2, 2, 2, 4]), [2, 4])
    }

    func testIDsAbsentFromTableAreIgnored() throws {
        let conn = try makeTable(rowCount: 3)
        XCTAssertEqual(try select(conn, ids: [2, 99, 100]), [2])
    }
}
