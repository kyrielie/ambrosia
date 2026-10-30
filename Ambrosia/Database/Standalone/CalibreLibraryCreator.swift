// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import SQLite

public enum CalibreLibraryCreatorError: Error, LocalizedError {
    case databaseAlreadyExists(URL)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseAlreadyExists(let url):
            return "A Calibre metadata.db already exists at \(url.path)."
        case .executionFailed(let msg):
            return "Failed to initialize Calibre database: \(msg)"
        }
    }
}

/// Creates a new Calibre-compatible `metadata.db` file from scratch.
public enum CalibreLibraryCreator {

    /// Creates and seeds an empty Calibre `metadata.db` inside the given root folder.
    @discardableResult
    public static func createEmptyLibrary(at rootURL: URL, overwrite: Bool = false) throws -> Connection {
        let dbURL = rootURL.appendingPathComponent("metadata.db")
        if !overwrite && FileManager.default.fileExists(atPath: dbURL.path) {
            throw CalibreLibraryCreatorError.databaseAlreadyExists(dbURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let conn = try Connection(dbURL.path)
        CalibreFunctions.register(on: conn)

        try conn.execute("PRAGMA foreign_keys = ON;")
        try conn.execute("PRAGMA journal_mode = WAL;")

        // Execute DDL via sqlite3_exec to handle the full multiline script with multiple statements and triggers
        var errMsg: UnsafeMutablePointer<CChar>?
        let ddlResult = sqlite3_exec(conn.handle, CalibreSchema.sql, nil, nil, &errMsg)
        if ddlResult != SQLITE_OK {
            let errorText = errMsg.map { String(cString: $0) } ?? "Unknown error (code \(ddlResult))"
            sqlite3_free(errMsg)
            throw CalibreLibraryCreatorError.executionFailed(errorText)
        }

        // Seed library_id with a persistent UUID
        let libraryUUID = UUID().uuidString.lowercased()
        try conn.run("INSERT INTO library_id (uuid) VALUES (?)", libraryUUID)

        // Seed default preferences expected by Calibre
        try conn.run("INSERT INTO preferences (key, val) VALUES (?, ?)", "calibre_uuid", libraryUUID)
        try conn.run("INSERT INTO preferences (key, val) VALUES (?, ?)", "installed_plugins", "[]")
        try conn.run("INSERT INTO preferences (key, val) VALUES (?, ?)", "column_color_rules", "[]")
        try conn.run("INSERT INTO preferences (key, val) VALUES (?, ?)", "column_icon_rules", "[]")

        return conn
    }
}
