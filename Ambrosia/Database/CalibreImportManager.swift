// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite

struct CalibreImportResult: Sendable {
    let addedIDs: [Int]
    let updatedIDs: [Int]
    let skippedCount: Int
    let errors: [String]
}

enum CalibreImportError: Error, LocalizedError {
    case noActiveLibrary
    case calibreAppRunning
    case bookOpenInReader([Int])

    var errorDescription: String? {
        switch self {
        case .noActiveLibrary:
            return "No active library is currently open."
        case .calibreAppRunning:
            return "Calibre is currently running. Quit Calibre before importing or updating books."
        case .bookOpenInReader(let ids):
            let list = ids.map { "#\($0)" }.joined(separator: ", ")
            return "Close the open Reader window for book \(list) before updating it."
        }
    }
}

/// Executes triaged EPUB additions and in-place chapter updates across
/// Tier 1 (`calibredb`), Tier 2 (Standalone `CalibreLibraryWriter`), and Tier 3 (guarded SQLite fallback).
enum CalibreImportManager {

    @MainActor
    static func commitImport(
        items: [EPUBImportTriageItem],
        session: LibrarySession,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> CalibreImportResult {
        guard let activePath = session.activePath else {
            throw CalibreImportError.noActiveLibrary
        }
        let rootURL = URL(fileURLWithPath: activePath)
        let activeItems = items.filter { $0.selectedAction.isMutating }
        let skippedCount = items.count - activeItems.count

        guard !activeItems.isEmpty else {
            return CalibreImportResult(addedIDs: [], updatedIDs: [], skippedCount: skippedCount, errors: [])
        }

        // Open-reader guard for in-place updates/replacements
        let openIDs = CalibreCLIBridge.openReaderBookIDs()
        let blockedIDs = activeItems.compactMap { item -> Int? in
            guard item.selectedAction == .updateExisting || item.selectedAction == .replaceExisting,
                  let targetID = item.matchedBook?.calibreID,
                  openIDs.contains(targetID) else { return nil }
            return targetID
        }
        if !blockedIDs.isEmpty {
            throw CalibreImportError.bookOpenInReader(blockedIDs)
        }

        let mode = CalibreCLIBridge.detectMutationMode(at: rootURL)
        if mode == .calibreManaged, CalibreCLIBridge.isCalibreAppRunning() {
            throw CalibreImportError.calibreAppRunning
        }
        let calibredbURL = mode == .calibreManaged ? CalibreCLIBridge.resolveCalibredbURL() : nil

        var addedIDs: [Int] = []
        var updatedIDs: [Int] = []
        var errors: [String] = []
        let total = activeItems.count

        for (idx, item) in activeItems.enumerated() {
            progress?(idx + 1, total, item.incoming.title)

            do {
                switch item.selectedAction {
                case .skip:
                    break
                case .importNew, .keepBoth:
                    let newID = try await addBook(
                        incomingURL: item.incoming.url,
                        rootURL: rootURL,
                        mode: mode,
                        calibredbURL: calibredbURL
                    )
                    if let newID { addedIDs.append(newID) }
                case .updateExisting, .replaceExisting:
                    guard let matched = item.matchedBook else {
                        let newID = try await addBook(
                            incomingURL: item.incoming.url,
                            rootURL: rootURL,
                            mode: mode,
                            calibredbURL: calibredbURL
                        )
                        if let newID { addedIDs.append(newID) }
                        continue
                    }
                    if matched.annotationCount > 0, let metaDB = session.metaDB {
                        try? await AnnotationBackupManager.shared.flushNow(
                            calibreID: matched.calibreID,
                            libraryURL: rootURL,
                            metaDB: metaDB
                        )
                        if let oldURL = matched.epubURL, FileManager.default.fileExists(atPath: oldURL.path) {
                            await preflightAnnotationContextSnapshot(
                                calibreID: matched.calibreID,
                                epubURL: oldURL,
                                metaDB: metaDB
                            )
                        }
                        try? await metaDB.markBookAnnotationsNeedsReanchor(calibreID: matched.calibreID)
                    }
                    try await updateExistingBook(
                        incomingURL: item.incoming.url,
                        targetBook: matched,
                        rootURL: rootURL,
                        mode: mode,
                        calibredbURL: calibredbURL
                    )
                    try? await session.metaDB?.invalidateAO3Metadata(for: matched.calibreID)
                    updatedIDs.append(matched.calibreID)
                }
            } catch {
                errors.append("\(item.incoming.title): \(error.localizedDescription)")
            }
        }

        if mode == .standalone && (!addedIDs.isEmpty || !updatedIDs.isEmpty) {
            _ = await Task.detached(priority: .utility) {
                try? CalibreFTSWriter.indexLibrary(at: rootURL, batchSize: 10)
            }.value
        }

        await session.checkForLibraryChanges()
        return CalibreImportResult(
            addedIDs: addedIDs,
            updatedIDs: updatedIDs,
            skippedCount: skippedCount,
            errors: errors
        )
    }

    // MARK: - Add New Book

    private static func addBook(
        incomingURL: URL,
        rootURL: URL,
        mode: LibraryMutationMode,
        calibredbURL: URL?
    ) async throws -> Int? {
        if mode == .calibreManaged, let calibredbURL {
            let (code, stdout, stderr) = try await CalibreCLIBridge.runCalibredb(
                binaryURL: calibredbURL,
                libraryRoot: rootURL,
                arguments: ["add", "--duplicates", incomingURL.path]
            )
            guard code == 0 else {
                let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "CalibreImportManager",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? stdout : msg]
                )
            }
            return parseAddedBookID(from: stdout)
        }

        if mode == .standalone {
            return try await Task.detached(priority: .userInitiated) {
                let destURL = try copyIntoStandaloneFolderIfNeeded(sourceURL: incomingURL, rootURL: rootURL)
                let relPath = relativePath(of: destURL, from: rootURL)
                let size = fileSize(of: destURL)
                let discovered = DiscoveredEPUB(fileURL: destURL, relativePath: relPath, fileSize: size)
                _ = try CalibreLibraryWriter.importEPUBs(epubs: [discovered], into: rootURL, batchSize: 1)
                let dbURL = rootURL.appendingPathComponent("metadata.db")
                if let conn = try? Connection(dbURL.path, readonly: true),
                   let id = try? conn.scalar("SELECT id FROM books WHERE path = ? LIMIT 1", relPath) as? Int64 {
                    return Int(id)
                }
                return nil
            }.value
        }

        // Tier 3: Guarded direct Calibre-managed SQLite insert
        return try await Task.detached(priority: .userInitiated) {
            try insertBookTier3(incomingURL: incomingURL, rootURL: rootURL)
        }.value
    }

    // MARK: - Update Existing Book

    private static func updateExistingBook(
        incomingURL: URL,
        targetBook: MatchedLibraryBookSummary,
        rootURL: URL,
        mode: LibraryMutationMode,
        calibredbURL: URL?
    ) async throws {
        // Trash old EPUB first if present, keeping restore URL for rollback
        var trashedOldPair: (original: URL, trashed: URL)?
        if let oldURL = targetBook.epubURL, FileManager.default.fileExists(atPath: oldURL.path) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: oldURL, resultingItemURL: &resultingURL)
            if let restored = resultingURL as URL? {
                trashedOldPair = (original: oldURL, trashed: restored)
            }
        }

        do {
            if mode == .calibreManaged, let calibredbURL {
                let (code, stdout, stderr) = try await CalibreCLIBridge.runCalibredb(
                    binaryURL: calibredbURL,
                    libraryRoot: rootURL,
                    arguments: ["add_format", "--replace", String(targetBook.calibreID), incomingURL.path]
                )
                guard code == 0 else {
                    let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw NSError(
                        domain: "CalibreImportManager",
                        code: Int(code),
                        userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? stdout : msg]
                    )
                }
                return
            }

            try await Task.detached(priority: .userInitiated) {
                let dbURL = rootURL.appendingPathComponent("metadata.db")
                let fm = FileManager.default
                let destinationURL: URL
                if let existingURL = targetBook.epubURL {
                    destinationURL = existingURL
                } else {
                    destinationURL = try copyIntoStandaloneFolderIfNeeded(sourceURL: incomingURL, rootURL: rootURL)
                }
                if destinationURL.standardizedFileURL != incomingURL.standardizedFileURL {
                    if fm.fileExists(atPath: destinationURL.path) {
                        try fm.removeItem(at: destinationURL)
                    }
                    try fm.copyItem(at: incomingURL, to: destinationURL)
                }

                let newSize = fileSize(of: destinationURL)
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                let nowStr = isoFormatter.string(from: Date())

                let conn = try Connection(dbURL.path)
                conn.busyTimeout = 5.0
                CalibreFunctions.register(on: conn)
                try conn.execute("PRAGMA foreign_keys = ON;")
                try conn.transaction {
                    try conn.run("UPDATE books SET last_modified = ? WHERE id = ?", nowStr, targetBook.calibreID)
                    try conn.run(
                        "UPDATE data SET uncompressed_size = ? WHERE book = ? AND format = 'EPUB'",
                        newSize,
                        targetBook.calibreID
                    )
                }
            }.value
        } catch {
            if let pair = trashedOldPair {
                try? FileManager.default.moveItem(at: pair.trashed, to: pair.original)
            }
            throw error
        }
    }

    // MARK: - Helpers

    private static func parseAddedBookID(from stdout: String) -> Int? {
        guard let range = stdout.range(of: #"Added book ids:\s*(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(stdout[range])
        let digits = match.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }

    private static func copyIntoStandaloneFolderIfNeeded(sourceURL: URL, rootURL: URL) throws -> URL {
        let stdSource = sourceURL.standardizedFileURL.path
        let stdRoot = rootURL.standardizedFileURL.path
        if stdSource.hasPrefix(stdRoot + "/") {
            return sourceURL
        }
        let fm = FileManager.default
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var candidate = rootURL.appendingPathComponent("\(baseName).epub")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(baseName) (\(suffix)).epub")
            suffix += 1
        }
        try fm.copyItem(at: sourceURL, to: candidate)
        return candidate
    }

    private static func insertBookTier3(incomingURL: URL, rootURL: URL) throws -> Int {
        var parser = EPUBParser(epubURL: incomingURL)
        try? parser.parse()
        let rawTitle = parser.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle.isEmpty || rawTitle.lowercased() == "unknown")
            ? incomingURL.deletingPathExtension().lastPathComponent
            : rawTitle
        let creators = parser.opfCreators.isEmpty ? ["Unknown"] : parser.opfCreators
        let primaryAuthor = creators.first ?? "Unknown"
        let safeAuthor = sanitizeFilename(primaryAuthor)
        let safeTitle = sanitizeFilename(title)

        let dbURL = rootURL.appendingPathComponent("metadata.db")
        let conn = try Connection(dbURL.path)
        conn.busyTimeout = 5.0
        CalibreFunctions.register(on: conn)
        try conn.execute("PRAGMA foreign_keys = ON;")

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let nowStr = isoFormatter.string(from: Date())
        let authorSort = CalibreFunctions.authorSort(of: creators)

        var insertedID: Int64 = 0
        try conn.transaction {
            try conn.run(
                """
                INSERT INTO books (title, author_sort, timestamp, pubdate, series_index, last_modified, path, has_cover)
                VALUES (?, ?, ?, ?, 1.0, ?, '', 0)
                """,
                title,
                authorSort,
                nowStr,
                nowStr,
                nowStr
            )
            insertedID = conn.lastInsertRowid

            let relDir = "\(safeAuthor)/\(safeTitle) (\(insertedID))"
            let bookDir = rootURL.appendingPathComponent(relDir)
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

            let fileStem = "\(safeTitle) - \(safeAuthor)"
            let destEPUB = bookDir.appendingPathComponent("\(fileStem).epub")
            try FileManager.default.copyItem(at: incomingURL, to: destEPUB)

            try conn.run("UPDATE books SET path = ? WHERE id = ?", relDir, insertedID)
            try conn.run(
                "INSERT INTO data (book, format, uncompressed_size, name) VALUES (?, 'EPUB', ?, ?)",
                insertedID,
                fileSize(of: destEPUB),
                fileStem
            )
        }
        return Int(insertedID)
    }

    private static func preflightAnnotationContextSnapshot(
        calibreID: Int,
        epubURL: URL,
        metaDB: AmbrosiaMetaDB
    ) async {
        guard let existing = try? await metaDB.annotations(for: calibreID) else { return }
        let needingContext = existing.filter { $0.quotePrefix.isEmpty && $0.quoteSuffix.isEmpty }
        guard !needingContext.isEmpty else { return }

        let extracted: [(id: UUID, href: String, prefix: String, suffix: String)] = await Task.detached(
            priority: .utility
        ) {
            var parser = EPUBParser(epubURL: epubURL)
            guard (try? parser.parse()) != nil else { return [] }
            var plainTextCache: [Int: String] = [:]
            var updates: [(UUID, String, String, String)] = []

            for ann in needingContext {
                guard parser.spine.indices.contains(ann.spineIndex) else { continue }
                let item = parser.spine[ann.spineIndex]
                let text: String
                if let cached = plainTextCache[ann.spineIndex] {
                    text = cached
                } else if let parsed = try? parser.plainText(for: item) {
                    plainTextCache[ann.spineIndex] = parsed
                    text = parsed
                } else {
                    continue
                }

                let utf16 = text.utf16
                let total = utf16.count
                let clampedStart = max(0, min(ann.startChar, total))
                let clampedEnd = max(clampedStart, min(ann.endChar, total))
                let prefixStart = max(0, clampedStart - 200)
                let suffixEnd = min(total, clampedEnd + 200)

                let prefixIdxStart = utf16.index(utf16.startIndex, offsetBy: prefixStart)
                let prefixIdxEnd = utf16.index(utf16.startIndex, offsetBy: clampedStart)
                let suffixIdxStart = utf16.index(utf16.startIndex, offsetBy: clampedEnd)
                let suffixIdxEnd = utf16.index(utf16.startIndex, offsetBy: suffixEnd)

                let prefix = String(utf16[prefixIdxStart..<prefixIdxEnd]) ?? ""
                let suffix = String(utf16[suffixIdxStart..<suffixIdxEnd]) ?? ""
                updates.append((ann.id, item.href, prefix, suffix))
            }
            return updates
        }.value

        for item in extracted {
            try? await metaDB.updateAnnotationAnchorContext(
                id: item.id,
                spineHref: item.href,
                quotePrefix: item.prefix,
                quoteSuffix: item.suffix,
                chapterTitle: nil
            )
        }
    }

    private static func relativePath(of fileURL: URL, from rootURL: URL) -> String {
        let stdFile = fileURL.standardizedFileURL.path
        let stdRoot = rootURL.standardizedFileURL.path
        guard stdFile.hasPrefix(stdRoot) else { return fileURL.lastPathComponent }
        var rel = String(stdFile.dropFirst(stdRoot.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    private static func fileSize(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }
}
