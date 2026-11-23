import XCTest
import SQLite
@testable import Ambrosia

final class SQLiteFileMaintenanceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteFileMaintenanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTotalFileSizeSumsDatabaseWalAndShm() throws {
        let base = directory.appendingPathComponent("x.db")
        try Data(count: 100).write(to: base)
        try Data(count: 20).write(to: directory.appendingPathComponent("x.db-wal"))
        try Data(count: 3).write(to: directory.appendingPathComponent("x.db-shm"))
        XCTAssertEqual(SQLiteFileMaintenance.totalFileSize(baseFileURL: base), 123)
    }

    func testTotalFileSizeIgnoresMissingSiblings() throws {
        let base = directory.appendingPathComponent("y.db")
        try Data(count: 64).write(to: base)
        XCTAssertEqual(SQLiteFileMaintenance.totalFileSize(baseFileURL: base), 64)
    }

    func testTotalFileSizeOfMissingDatabaseIsZero() {
        let base = directory.appendingPathComponent("missing.db")
        XCTAssertEqual(SQLiteFileMaintenance.totalFileSize(baseFileURL: base), 0)
    }

    func testCheckpointAndVacuumShrinksDatabaseAfterDeletes() throws {
        let url = directory.appendingPathComponent("v.db")
        let connection = try Connection(url.path)
        try connection.execute("CREATE TABLE t (x BLOB)")
        for _ in 0..<200 {
            try connection.run("INSERT INTO t VALUES (zeroblob(4096))")
        }
        try connection.run("DELETE FROM t")
        let before = SQLiteFileMaintenance.totalFileSize(baseFileURL: url)

        SQLiteFileMaintenance.checkpointAndVacuum(connection)

        let after = SQLiteFileMaintenance.totalFileSize(baseFileURL: url)
        XCTAssertLessThan(after, before)
    }
}
