import Foundation
import Observation

extension Notification.Name {
    static let seriesOrMergedCollectionDidChange = Notification.Name("Ambrosia.seriesOrMergedCollectionDidChange")
}

/// Holds the active CalibreLibrary connection for the current session.
/// Opened when the user picks a folder or on launch if a path was saved.
/// Replaced wholesale when the user switches libraries — no import, no sync.
///
/// Injected into the SwiftUI environment so all views share one instance.
@Observable
@MainActor
final class LibrarySession {

    /// The open library connection. Nil until the user picks a folder.
    private(set) var library: CalibreLibrary?

    /// Optional full-text-search connection. Nil if full-text-search.db doesn't exist.
    private(set) var ftsLibrary: CalibreFTSLibrary?

    /// Per-library app-owned SQLite database for collections and annotations.
    private(set) var metaDB: AmbrosiaMetaDB?

    let extractionProgress = ExtractionProgress()

    /// Typed collection operations for the active library.
    private(set) var collectionStore: CollectionStore?

    /// Cached total book count from metadata.db. Refreshed on library open
    /// and on search input (debounced). Never recomputed on page turns.
    private(set) var totalCount: Int = 0

    /// The path of the currently open library.
    private(set) var activePath: String?

    /// True while a library is open and ready to query.
    var isOpen: Bool { library != nil }

    /// Error from the last open attempt, shown in the UI if non-nil.
    private(set) var lastError: String?

    private var extractionTask: Task<Void, Never>?

    // MARK: - Opening / closing

    /// Open a Calibre library at the given URL.
    func open(url: URL) {
        lastError = nil
        do {
            let newLibrary = try CalibreLibrary(root: url)
            let newMetaDB = try AmbrosiaMetaDB(libraryURL: url)
            library    = newLibrary
            metaDB = newMetaDB
            collectionStore = CollectionStore(db: newMetaDB)
            activePath = url.path
            totalCount = newLibrary.bookCount()
            ftsLibrary = CalibreFTSLibrary(libraryURL: url)
            LibraryRegistry.shared.register(url)
            LibraryIndexManager.shared.record(url: url)
            startAO3Extraction()
            seedCalibreSeriesCache()
            print("[LibrarySession] Opened \(url.lastPathComponent) — \(totalCount) books")
        } catch {
            lastError = "Could not open library: \(error.localizedDescription)"
            print("[LibrarySession] Open failed: \(error)")
        }
    }

    func close() {
        extractionTask?.cancel()
        extractionTask = nil
        extractionProgress.isRunning = false
        extractionProgress.completed = 0
        extractionProgress.total = 0
        library    = nil
        ftsLibrary = nil
        metaDB = nil
        collectionStore = nil
        totalCount = 0
        activePath = nil
    }

    // MARK: - Count refresh

    func refreshCount(query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])) {
        guard let library else { return }
        if query.isEmpty {
            totalCount = library.bookCount()
        } else {
            totalCount = library.bookCount(query: query)
        }
    }

    // MARK: - FTS resolution

    /// Attempts FTS resolution for plain terms; falls back to LIKE if FTS unavailable or empty.
    /// Shared between list view and email view — single source of truth.
    func resolvedQuery(_ query: SearchQuery) -> SearchQuery {
        guard !query.plainTerms.isEmpty,
              let fts = ftsLibrary else { return query }
        let plainText = query.plainTerms.joined(separator: " ")
        guard let ftsIDs = fts.search(query: plainText), !ftsIDs.isEmpty else {
            return query
        }
        return SearchQuery(
            tagTerms:     query.tagTerms,
            authorTerms:  query.authorTerms,
            titleTerms:   query.titleTerms,
            seriesTerms:  query.seriesTerms,
            plainTerms:   [],
            ftsMatchedIDs: ftsIDs
        )
    }

    // MARK: - Re-open saved library on launch

    func reopenIfNeeded() {
        guard library == nil,
              let path = LibraryRegistry.shared.activePath,
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard LibraryRegistry.shared.isValid(path) else {
            print("[LibrarySession] Saved path no longer valid: \(path)")
            return
        }
        open(url: url)
    }

    func reextractAO3Metadata() {
        guard metaDB != nil else { return }
        extractionTask?.cancel()
        Task {
            do {
                try await metaDB?.clearAO3Metadata()
                await MainActor.run {
                    self.seedCalibreSeriesCache()
                    self.startAO3Extraction(forceAll: true)
                }
            } catch {
                print("[LibrarySession] AO3 metadata reset failed: \(error)")
            }
        }
    }

    private func startAO3Extraction(forceAll: Bool = false) {
        extractionTask?.cancel()
        guard let library, let metaDB else { return }

        extractionProgress.completed = 0
        extractionProgress.total = 0
        extractionProgress.isRunning = true

        extractionTask = Task(priority: .background) { [weak self, library, metaDB] in
            let allIDs = library.allBookIDs()
            let existing = (try? await metaDB.existingAO3MetadataIDs()) ?? []
            let missing = forceAll ? allIDs : allIDs.filter { !existing.contains($0) }

            DispatchQueue.main.async { [weak self] in
                self?.extractionProgress.total = missing.count
                self?.extractionProgress.completed = 0
                self?.extractionProgress.isRunning = !missing.isEmpty
            }

            guard !missing.isEmpty else { return }

            for id in missing {
                if Task.isCancelled { break }
                var failureReason: String?
                var failureStatus = "skipped"
                var diagnosticEPUB: URL?
                var spineItemsChecked: Int?
                let metadata = autoreleasepool { () -> AO3MetadataRecord? in
                    guard let epub = library.epubURL(calibreID: id) else {
                        failureReason = "no EPUB found"
                        return nil
                    }
                    diagnosticEPUB = epub
                    do {
                        var parser = EPUBParser(epubURL: epub)
                        try parser.parse()
                        let checkedItems = Array(parser.spine.prefix(5))
                        spineItemsChecked = checkedItems.count
                        for item in checkedItems {
                            let html = try parser.html(for: item, userCSS: "")
                            if let metadata = AO3MetadataExtractor.extract(from: html) {
                                return metadata
                            }
                        }
                        failureReason = "no dl.tags AO3 preface metadata in first \(min(parser.spine.count, 5)) spine items"
                        return nil
                    } catch {
                        failureStatus = "failed"
                        failureReason = error.localizedDescription
                        return nil
                    }
                }
                if let metadata {
                    try? await metaDB.insert(metadata, calibreID: id)
                } else {
                    let diagnostic = AO3ExtractionDiagnostic(
                        calibreID: id,
                        status: failureStatus,
                        reason: failureReason ?? "unknown reason",
                        epubPath: diagnosticEPUB?.path,
                        epubFilename: diagnosticEPUB?.lastPathComponent,
                        spineItemsChecked: spineItemsChecked,
                        attemptedAt: ISO8601DateFormatter().string(from: Date())
                    )
                    try? await metaDB.insert(diagnostic)
                    print("[LibrarySession] AO3 extraction skipped calibreID=\(id): \(failureReason ?? "unknown reason")")
                }
                DispatchQueue.main.async { [weak self] in
                    self?.extractionProgress.completed += 1
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.extractionProgress.isRunning = false
            }
            await self?.syncSeriesOrMergedCollection()
        }
    }

    private func seedCalibreSeriesCache() {
        guard let library, let metaDB else { return }
        Task.detached(priority: .background) { [weak self, library, metaDB] in
            let entries = library.allCalibreSeriesEntries()
            do {
                try await metaDB.insertCalibreSeriesFallback(entries)
                await self?.syncSeriesOrMergedCollection()
            } catch {
                print("[LibrarySession] Calibre series cache seed failed: \(error)")
            }
        }
    }

    func syncSeriesOrMergedCollection() async {
        guard let library, let metaDB, let collectionStore else { return }
        do {
            var ids = try await metaDB.collapsedSeriesMemberIDs()
            ids.formUnion(library.anthologyBookIDs())
            try await collectionStore.replaceMembers(of: SystemCollectionID.seriesOrMerged, with: ids)
            await MainActor.run {
                NotificationCenter.default.post(name: .seriesOrMergedCollectionDidChange, object: nil)
            }
        } catch {
            print("[LibrarySession] Series or Merged sync failed: \(error)")
        }
    }
}
