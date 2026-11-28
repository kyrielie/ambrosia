// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ImportTriageCategory: String, CaseIterable, Identifiable, Sendable {
    case conflict = "Conflicts"
    case newerRevision = "Updates"
    case newBook = "New"
    case exactDuplicate = "Exact Duplicates"
    case olderRevision = "Older Revisions"
    case anthology = "Anthologies"

    var id: String { rawValue }
}

enum ImportResolutionAction: String, CaseIterable, Identifiable, Sendable {
    case importNew = "Import as New"
    case updateExisting = "Update Existing"
    case keepBoth = "Keep Both (New Edition)"
    case replaceExisting = "Replace Existing"
    case skip = "Skip"

    var id: String { rawValue }

    var isMutating: Bool { self != .skip }
}

struct IncomingEPUBSummary: Sendable {
    let url: URL
    let fileSize: Int64
    let title: String
    let authors: [String]
    let ao3WorkID: String?
    let chapterCurrent: Int?
    let chapterTotal: Int?
    let wordCount: Int?
    let updatedDate: String?
    let publishedDate: String?
    let isAnthology: Bool
    let prefaceStatsFound: Bool
}

struct MatchedLibraryBookSummary: Sendable {
    let calibreID: Int
    let title: String
    let authors: [String]
    let ao3WorkID: String?
    let chapterCurrent: Int?
    let chapterTotal: Int?
    let wordCount: Int?
    let updatedDate: String?
    let publishedDate: String?
    let fileSize: Int64?
    let readPercent: Double
    let isLiked: Bool
    let isReadLater: Bool
    let annotationCount: Int
    let isOpenInReader: Bool
    let epubURL: URL?
}

struct EPUBImportTriageItem: Identifiable, Sendable {
    let id: UUID
    let incoming: IncomingEPUBSummary
    let matchedBook: MatchedLibraryBookSummary?
    let category: ImportTriageCategory
    let matchReason: String
    let recommendedAction: ImportResolutionAction
    var selectedAction: ImportResolutionAction
    let hasByteOrContentMatch: Bool

    var availableActions: [ImportResolutionAction] {
        if matchedBook == nil {
            return [.importNew, .skip]
        }
        return [.updateExisting, .keepBoth, .replaceExisting, .skip]
    }
}

/// Inspects dropped/selected EPUB files in memory and classifies each against
/// the active library before any database or filesystem mutation occurs.
enum EPUBImportTriageEngine {

    /// Expands mixed file/folder URLs into a deduplicated, sorted list of `.epub` URLs.
    static func collectEPUBURLs(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var collected: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                for epub in EPUBFolderScanner.scan(rootURL: url) {
                    let std = epub.fileURL.standardizedFileURL.path
                    if seen.insert(std).inserted {
                        collected.append(epub.fileURL)
                    }
                }
            } else if url.pathExtension.lowercased() == "epub" {
                let std = url.standardizedFileURL.path
                if seen.insert(std).inserted {
                    collected.append(url)
                }
            }
        }
        return collected
    }

    /// Parses incoming EPUBs off the main actor and matches them against `session`'s active library.
    static func inspectAndTriage(
        epubURLs: [URL],
        session: LibrarySession,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> (items: [EPUBImportTriageItem], errors: [String]) {
        let (maybeLibrary, maybeMetaDB, openReaderIDs, likedIDs, readLaterIDs) = await MainActor.run {
            (
                session.library,
                session.metaDB,
                CalibreCLIBridge.openReaderBookIDs(),
                session.effectiveLikedIDs,
                session.effectiveReadLaterIDs
            )
        }
        guard let library = maybeLibrary, let metaDB = maybeMetaDB else {
            return ([], ["No active library is currently open."])
        }

        let snapshots = await metaDB.allAO3HealthSnapshots()
        let anthologyIDs = await metaDB.allAnthologyCacheIDs()

        // Index snapshots by AO3 Work ID (skipping anthologies)
        var workIDMap: [String: [AmbrosiaMetaDB.AO3HealthSnapshot]] = [:]
        for snap in snapshots where !anthologyIDs.contains(snap.calibreID) {
            if let wid = snap.workID, !wid.isEmpty {
                workIDMap[wid, default: []].append(snap)
            }
        }

        var items: [EPUBImportTriageItem] = []
        var errors: [String] = []
        let total = epubURLs.count

        for (index, url) in epubURLs.enumerated() {
            let filename = url.deletingPathExtension().lastPathComponent
            progress?(index + 1, total, filename)

            let parsed = await Task.detached(priority: .userInitiated) {
                parseIncomingEPUB(at: url)
            }.value

            guard let incoming = parsed else {
                errors.append("Could not read EPUB metadata: \(url.lastPathComponent)")
                continue
            }

            if incoming.isAnthology {
                items.append(EPUBImportTriageItem(
                    id: UUID(),
                    incoming: incoming,
                    matchedBook: nil,
                    category: .anthology,
                    matchReason: "Multi-work anthology EPUB",
                    recommendedAction: .importNew,
                    selectedAction: .importNew,
                    hasByteOrContentMatch: false
                ))
                continue
            }

            // Primary match: AO3 Work ID
            var candidateSnapshots: [AmbrosiaMetaDB.AO3HealthSnapshot] = []
            if let wid = incoming.ao3WorkID, let matches = workIDMap[wid], !matches.isEmpty {
                candidateSnapshots = matches
            }

            // Secondary match: Normalized Title + Authors
            if candidateSnapshots.isEmpty {
                let matchingIDs = await library.findBookIDs(
                    matchingNormalizedTitle: incoming.title,
                    authors: incoming.authors
                )
                if !matchingIDs.isEmpty {
                    let idSet = Set(matchingIDs)
                    candidateSnapshots = snapshots.filter { idSet.contains($0.calibreID) }
                }
            }

            guard let bestMatchSnap = chooseBestMatchSnapshot(from: candidateSnapshots) else {
                items.append(EPUBImportTriageItem(
                    id: UUID(),
                    incoming: incoming,
                    matchedBook: nil,
                    category: .newBook,
                    matchReason: "No matching work in library",
                    recommendedAction: .importNew,
                    selectedAction: .importNew,
                    hasByteOrContentMatch: false
                ))
                continue
            }

            let matchedBook = await buildMatchedBookSummary(
                snapshot: bestMatchSnap,
                library: library,
                metaDB: metaDB,
                openReaderIDs: openReaderIDs,
                collectionFlags: (likedIDs.contains(bestMatchSnap.calibreID), readLaterIDs.contains(bestMatchSnap.calibreID))
            )

            let triage = await classifyMatch(
                incoming: incoming,
                matched: matchedBook,
                matchedByAO3ID: incoming.ao3WorkID != nil && incoming.ao3WorkID == bestMatchSnap.workID
            )
            items.append(triage)
        }

        return (sortTriageItems(items), errors)
    }

    // MARK: - Private Helpers

    private static func parseIncomingEPUB(at url: URL) -> IncomingEPUBSummary? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        var parser = EPUBParser(epubURL: url)
        do {
            try parser.parse()
        } catch {
            return nil
        }

        let isAnthology = DuplicateVerificationService.isAnthologyArchive(at: url)
        var title = parser.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.lowercased() == "unknown" {
            title = url.deletingPathExtension().lastPathComponent
        }
        let authors = parser.opfCreators.isEmpty ? ["Unknown"] : parser.opfCreators

        var ao3Record: AO3MetadataRecord?
        for item in parser.spine.prefix(3) {
            if let html = try? parser.html(for: item, userCSS: ""),
               let record = AO3MetadataExtractor.extract(from: html) {
                ao3Record = record
                break
            }
        }

        return IncomingEPUBSummary(
            url: url,
            fileSize: fileSize,
            title: title,
            authors: authors,
            ao3WorkID: ao3Record?.workID,
            chapterCurrent: ao3Record?.chapterCurrent,
            chapterTotal: ao3Record?.chapterTotal,
            wordCount: ao3Record?.wordCount,
            updatedDate: ao3Record?.updatedDate,
            publishedDate: ao3Record?.publishedDate,
            isAnthology: isAnthology,
            prefaceStatsFound: ao3Record != nil
        )
    }

    private static func chooseBestMatchSnapshot(
        from candidates: [AmbrosiaMetaDB.AO3HealthSnapshot]
    ) -> AmbrosiaMetaDB.AO3HealthSnapshot? {
        candidates.max { lhs, rhs in
            let lCh = lhs.chapterCurrent ?? 0
            let rCh = rhs.chapterCurrent ?? 0
            if lCh != rCh { return lCh < rCh }
            let lWords = lhs.wordCount ?? 0
            let rWords = rhs.wordCount ?? 0
            if lWords != rWords { return lWords < rWords }
            return lhs.calibreID < rhs.calibreID
        }
    }

    private static func buildMatchedBookSummary(
        snapshot: AmbrosiaMetaDB.AO3HealthSnapshot,
        library: CalibreLibrary,
        metaDB: AmbrosiaMetaDB,
        openReaderIDs: Set<Int>,
        collectionFlags: (isLiked: Bool, isReadLater: Bool)
    ) async -> MatchedLibraryBookSummary {
        let bookID = snapshot.calibreID
        let books = await library.booksForIDs([bookID])
        let book = books.first
        let epubURL = await library.epubURL(calibreID: bookID)
        let state = await metaDB.bookStates(for: [bookID])[bookID]
        let annCount = await metaDB.annotationCount(for: bookID)
        let fileSize: Int64? = epubURL.flatMap { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value
        }

        return MatchedLibraryBookSummary(
            calibreID: bookID,
            title: book?.displayTitle ?? "Book #\(bookID)",
            authors: (book?.displayAuthors ?? "Unknown")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            ao3WorkID: snapshot.workID,
            chapterCurrent: snapshot.chapterCurrent,
            chapterTotal: snapshot.chapterTotal,
            wordCount: snapshot.wordCount,
            updatedDate: snapshot.updatedDate,
            publishedDate: snapshot.publishedDate,
            fileSize: fileSize,
            readPercent: state?.totalReadPercent ?? 0.0,
            isLiked: collectionFlags.isLiked,
            isReadLater: collectionFlags.isReadLater,
            annotationCount: annCount,
            isOpenInReader: openReaderIDs.contains(bookID),
            epubURL: epubURL
        )
    }

    private static func classifyMatch(
        incoming: IncomingEPUBSummary,
        matched: MatchedLibraryBookSummary,
        matchedByAO3ID: Bool
    ) async -> EPUBImportTriageItem {
        let matchPrefix = matchedByAO3ID
            ? "Matched by AO3 ID #\(incoming.ao3WorkID ?? "")"
            : "Matched by Title & Author"

        // Tertiary verification: check exact byte SHA-256 or ZIP CRC-32 match
        let isBinaryMatch = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let existingURL = matched.epubURL else { return false }
            if let inHash = try? DuplicateVerificationService.sha256(of: incoming.url),
               let exHash = try? DuplicateVerificationService.sha256(of: existingURL),
               inHash == exHash {
                return true
            }
            if let inSig = DuplicateVerificationService.zipContentSignature(of: incoming.url),
               let exSig = DuplicateVerificationService.zipContentSignature(of: existingURL),
               inSig == exSig {
                return true
            }
            return false
        }.value

        if isBinaryMatch {
            return EPUBImportTriageItem(
                id: UUID(),
                incoming: incoming,
                matchedBook: matched,
                category: .exactDuplicate,
                matchReason: "\(matchPrefix) · Exact EPUB match",
                recommendedAction: .skip,
                selectedAction: .skip,
                hasByteOrContentMatch: true
            )
        }

        // Preface-first comparison (handles Nectar exports cleanly)
        let inCh = incoming.chapterCurrent ?? 0
        let exCh = matched.chapterCurrent ?? 0
        let inWords = incoming.wordCount ?? 0
        let exWords = matched.wordCount ?? 0
        let wordDelta = inWords - exWords
        let inDate = incoming.updatedDate ?? incoming.publishedDate ?? ""
        let exDate = matched.updatedDate ?? matched.publishedDate ?? ""

        if inCh > 0 && exCh > 0 {
            if inCh > exCh {
                let delta = inCh - exCh
                return EPUBImportTriageItem(
                    id: UUID(),
                    incoming: incoming,
                    matchedBook: matched,
                    category: .newerRevision,
                    matchReason: "\(matchPrefix) · +\(delta) chapter\(delta == 1 ? "" : "s")",
                    recommendedAction: .updateExisting,
                    selectedAction: .updateExisting,
                    hasByteOrContentMatch: false
                )
            }
            if inCh < exCh {
                let delta = exCh - inCh
                return EPUBImportTriageItem(
                    id: UUID(),
                    incoming: incoming,
                    matchedBook: matched,
                    category: .olderRevision,
                    matchReason: "\(matchPrefix) · Library has +\(delta) more chapter\(delta == 1 ? "" : "s")",
                    recommendedAction: .skip,
                    selectedAction: .skip,
                    hasByteOrContentMatch: false
                )
            }
            // Same chapter count
            let completedUpgrade = incoming.chapterTotal != nil
                && incoming.chapterCurrent == incoming.chapterTotal
                && matched.chapterTotal == nil
            if completedUpgrade {
                return EPUBImportTriageItem(
                    id: UUID(),
                    incoming: incoming,
                    matchedBook: matched,
                    category: .newerRevision,
                    matchReason: "\(matchPrefix) · Marked complete",
                    recommendedAction: .updateExisting,
                    selectedAction: .updateExisting,
                    hasByteOrContentMatch: false
                )
            }
            if abs(wordDelta) <= 10 && inDate == exDate {
                return EPUBImportTriageItem(
                    id: UUID(),
                    incoming: incoming,
                    matchedBook: matched,
                    category: .exactDuplicate,
                    matchReason: "\(matchPrefix) · Identical chapter & word stats",
                    recommendedAction: .skip,
                    selectedAction: .skip,
                    hasByteOrContentMatch: false
                )
            }
            if abs(wordDelta) > 500 || (!inDate.isEmpty && !exDate.isEmpty && inDate != exDate) {
                let reason = abs(wordDelta) > 500
                    ? "\(matchPrefix) · Same chapters, \(wordDelta > 0 ? "+" : "")\(wordDelta.formatted()) words"
                    : "\(matchPrefix) · Date mismatch (\(inDate) vs \(exDate))"
                return EPUBImportTriageItem(
                    id: UUID(),
                    incoming: incoming,
                    matchedBook: matched,
                    category: .conflict,
                    matchReason: reason,
                    recommendedAction: .skip,
                    selectedAction: .skip,
                    hasByteOrContentMatch: false
                )
            }
            return EPUBImportTriageItem(
                id: UUID(),
                incoming: incoming,
                matchedBook: matched,
                category: .exactDuplicate,
                matchReason: "\(matchPrefix) · Same chapters & word count",
                recommendedAction: .skip,
                selectedAction: .skip,
                hasByteOrContentMatch: false
            )
        }

        // Fallback if chapter counts are missing
        if !inDate.isEmpty && !exDate.isEmpty && inDate > exDate {
            return EPUBImportTriageItem(
                id: UUID(),
                incoming: incoming,
                matchedBook: matched,
                category: .newerRevision,
                matchReason: "\(matchPrefix) · Newer date (\(inDate))",
                recommendedAction: .updateExisting,
                selectedAction: .updateExisting,
                hasByteOrContentMatch: false
            )
        }
        return EPUBImportTriageItem(
            id: UUID(),
            incoming: incoming,
            matchedBook: matched,
            category: .conflict,
            matchReason: "\(matchPrefix) · Compare editions manually",
            recommendedAction: .skip,
            selectedAction: .skip,
            hasByteOrContentMatch: false
        )
    }

    private static func sortTriageItems(_ items: [EPUBImportTriageItem]) -> [EPUBImportTriageItem] {
        let priority: [ImportTriageCategory: Int] = [
            .conflict: 0,
            .newerRevision: 1,
            .newBook: 2,
            .anthology: 3,
            .exactDuplicate: 4,
            .olderRevision: 5
        ]
        return items.sorted { lhs, rhs in
            let pL = priority[lhs.category] ?? 99
            let pR = priority[rhs.category] ?? 99
            if pL != pR { return pL < pR }
            return lhs.incoming.title.localizedCaseInsensitiveCompare(rhs.incoming.title) == .orderedAscending
        }
    }
}
