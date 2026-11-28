// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite

enum TrashDestination: Equatable, Sendable {
    case calibreTrash
    case macOSTrash

    var displayName: String {
        switch self {
        case .calibreTrash: return "Calibre Trash (.caltrash)"
        case .macOSTrash: return "macOS Trash"
        }
    }
}

struct CalibreTrashResult: Sendable {
    let trashedIDs: [Int]
    let destination: TrashDestination
    let reclaimedBytes: Int64
}

enum CalibreTrashError: Error, LocalizedError {
    case noActiveLibrary
    case bookOpenInReader([Int])
    case calibreAppRunning
    case hardlinkDetected(Int)
    case calibredbFailed(String)
    case sqliteFailed(String)
    case trashFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveLibrary:
            return "No active library is currently open."
        case .bookOpenInReader(let ids):
            let idList = ids.map { "#\($0)" }.joined(separator: ", ")
            return "Close the open Reader window for book \(idList) before trashing it."
        case .calibreAppRunning:
            return "Calibre is currently running. Quit Calibre before modifying the library to prevent database corruption."
        case .hardlinkDetected(let id):
            return "Book #\(id) shares the same underlying file (hardlink) as another copy. Refusing to trash."
        case .calibredbFailed(let msg):
            return "calibredb remove failed: \(msg)"
        case .sqliteFailed(let msg):
            return "Database cleanup failed (files were restored): \(msg)"
        case .trashFailed(let msg):
            return "Could not move file(s) to macOS Trash: \(msg)"
        }
    }
}

/// Safely removes superseded or duplicate books from Calibre/Standalone libraries
/// using Tier 1 (`calibredb remove`), Tier 2 (Standalone trash-first SQLite), or Tier 3 (guarded SQLite fallback).
enum CalibreTrashManager {

    /// Predicts the destination that will be used for trashing in `rootURL`.
    static func predictedDestination(for rootURL: URL) -> TrashDestination {
        let mode = CalibreCLIBridge.detectMutationMode(at: rootURL)
        if mode == .calibreManaged, CalibreCLIBridge.resolveCalibredbURL() != nil {
            return .calibreTrash
        }
        return .macOSTrash
    }

    /// Safely migrates state (if `winnerByLoserID` provides a winner), removes books from `metadata.db`
    /// and disk (reversibly via `.caltrash` or macOS Trash), cleans `ambrosia_meta.db`, and refreshes `session`.
    @MainActor
    static func trashBooks(
        winnerByLoserID: [Int: Int] = [:],
        loserIDs: [Int],
        session: LibrarySession
    ) async throws -> CalibreTrashResult {
        guard let activePath = session.activePath else {
            throw CalibreTrashError.noActiveLibrary
        }
        let rootURL = URL(fileURLWithPath: activePath)
        let uniqueLosers = Array(Set(loserIDs)).sorted()
        guard !uniqueLosers.isEmpty else {
            return CalibreTrashResult(trashedIDs: [], destination: predictedDestination(for: rootURL), reclaimedBytes: 0)
        }

        // 1. Reject if any loser is open in a Reader window
        let openIDs = CalibreCLIBridge.openReaderBookIDs()
        let openLosers = uniqueLosers.filter { openIDs.contains($0) }
        if !openLosers.isEmpty {
            throw CalibreTrashError.bookOpenInReader(openLosers)
        }

        // Pre-trash annotation snapshot checkpoint
        if let metaDB = session.metaDB {
            for loserID in uniqueLosers where await metaDB.annotationCount(for: loserID) > 0 {
                try? await AnnotationBackupManager.shared.flushNow(
                    calibreID: loserID,
                    libraryURL: rootURL,
                    metaDB: metaDB
                )
            }
        }

        // 2. Reject hardlinks to winners
        if let library = session.library {
            for loserID in uniqueLosers {
                if let winnerID = winnerByLoserID[loserID],
                   let winnerURL = await library.epubURL(calibreID: winnerID),
                   let loserURL = await library.epubURL(calibreID: loserID),
                   DuplicateVerificationService.isSamePhysicalFile(winnerURL, loserURL) {
                    throw CalibreTrashError.hardlinkDetected(loserID)
                }
            }
        }

        // 3. Migrate reading state, annotations, and collection memberships to winners
        if let metaDB = session.metaDB {
            for loserID in uniqueLosers {
                if let winnerID = winnerByLoserID[loserID] {
                    try await metaDB.transferBookState(fromLoserID: loserID, toWinnerID: winnerID)
                }
            }
        }

        // 4. Execute deletion via Tier 1, Tier 2, or Tier 3
        let mode = CalibreCLIBridge.detectMutationMode(at: rootURL)
        let result: CalibreTrashResult

        if mode == .calibreManaged {
            if CalibreCLIBridge.isCalibreAppRunning() {
                throw CalibreTrashError.calibreAppRunning
            }
            if let calibredbURL = CalibreCLIBridge.resolveCalibredbURL() {
                result = try await trashViaCalibredb(
                    binaryURL: calibredbURL,
                    rootURL: rootURL,
                    bookIDs: uniqueLosers
                )
            } else {
                result = try await trashViaDirectSQLite(
                    rootURL: rootURL,
                    bookIDs: uniqueLosers,
                    mode: .calibreManaged
                )
            }
        } else {
            result = try await trashViaDirectSQLite(
                rootURL: rootURL,
                bookIDs: uniqueLosers,
                mode: .standalone
            )
        }

        // 5. Clean up derived rows in ambrosia_meta.db
        if let metaDB = session.metaDB {
            try? await metaDB.cleanupDeletedBooks(calibreIDs: uniqueLosers)
        }

        // 6. Refresh session caches and UI
        await session.checkForLibraryChanges()
        return result
    }

    // MARK: - Tier 1: calibredb remove

    private static func trashViaCalibredb(
        binaryURL: URL,
        rootURL: URL,
        bookIDs: [Int]
    ) async throws -> CalibreTrashResult {
        let sizeBytes = totalDiskSize(rootURL: rootURL, bookIDs: bookIDs)
        let args = ["remove"] + bookIDs.map(String.init)
        let (exitCode, stdout, stderr) = try await CalibreCLIBridge.runCalibredb(
            binaryURL: binaryURL,
            libraryRoot: rootURL,
            arguments: args
        )
        guard exitCode == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CalibreTrashError.calibredbFailed(detail.isEmpty ? fallback : detail)
        }
        return CalibreTrashResult(trashedIDs: bookIDs, destination: .calibreTrash, reclaimedBytes: sizeBytes)
    }

    // MARK: - Tier 2 & 3: Trash-First Pairwise Commit

    private static func trashViaDirectSQLite(
        rootURL: URL,
        bookIDs: [Int],
        mode: LibraryMutationMode
    ) async throws -> CalibreTrashResult {
        try await Task.detached(priority: .userInitiated) {
            let dbURL = rootURL.appendingPathComponent("metadata.db")
            let targets = resolveTrashTargets(rootURL: rootURL, dbURL: dbURL, bookIDs: bookIDs, mode: mode)
            let reclaimed = targets.reduce(Int64(0)) { $0 + fileSize(at: $1) }

            // Step A: Move files/directories to macOS Trash first, recording restore pairs
            var trashedPairs: [(original: URL, trashed: URL)] = []
            let fm = FileManager.default
            do {
                for url in targets where fm.fileExists(atPath: url.path) {
                    var resultingURL: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resultingURL)
                    if let restoredFrom = resultingURL as URL? {
                        trashedPairs.append((original: url, trashed: restoredFrom))
                    }
                }
            } catch {
                restoreTrashedItems(trashedPairs)
                throw CalibreTrashError.trashFailed(error.localizedDescription)
            }

            // Step B: Delete rows in metadata.db with foreign keys + Calibre functions
            do {
                let conn = try Connection(dbURL.path)
                conn.busyTimeout = 5.0
                CalibreFunctions.register(on: conn)
                try conn.execute("PRAGMA foreign_keys = ON;")
                try conn.execute("BEGIN IMMEDIATE;")
                do {
                    for bookID in bookIDs {
                        try conn.run("DELETE FROM books WHERE id = ?", bookID)
                    }
                    try conn.execute("COMMIT;")
                } catch {
                    try? conn.execute("ROLLBACK;")
                    throw error
                }
            } catch {
                restoreTrashedItems(trashedPairs)
                throw CalibreTrashError.sqliteFailed(error.localizedDescription)
            }

            return CalibreTrashResult(trashedIDs: bookIDs, destination: .macOSTrash, reclaimedBytes: reclaimed)
        }.value
    }

    private static func resolveTrashTargets(
        rootURL: URL,
        dbURL: URL,
        bookIDs: [Int],
        mode: LibraryMutationMode
    ) -> [URL] {
        guard let conn = try? Connection(dbURL.path, readonly: true) else { return [] }
        var urls: [URL] = []
        for bookID in bookIDs {
            if let relPath = try? conn.scalar("SELECT path FROM books WHERE id = ?", bookID) as? String,
               !relPath.isEmpty {
                let target = rootURL.appendingPathComponent(relPath)
                urls.append(target)
            }
            if mode == .standalone {
                let cover = rootURL.appendingPathComponent(".covers/\(bookID).jpg")
                if FileManager.default.fileExists(atPath: cover.path) {
                    urls.append(cover)
                }
            }
        }
        return urls
    }

    private static func restoreTrashedItems(_ pairs: [(original: URL, trashed: URL)]) {
        let fm = FileManager.default
        for pair in pairs.reversed() {
            let parent = pair.original.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? fm.moveItem(at: pair.trashed, to: pair.original)
        }
    }

    private static func totalDiskSize(rootURL: URL, bookIDs: [Int]) -> Int64 {
        let dbURL = rootURL.appendingPathComponent("metadata.db")
        let targets = resolveTrashTargets(rootURL: rootURL, dbURL: dbURL, bookIDs: bookIDs, mode: .calibreManaged)
        return targets.reduce(Int64(0)) { $0 + fileSize(at: $1) }
    }

    private static func fileSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(vals?.fileSize ?? 0)
        }
        return total
    }
}
