import Foundation
import AppKit

// MARK: - §3b: Tag export options

/// Controls which tag categories appear in the CSV "Tags" column.
/// Defaults: all AO3 structural tags on; freeform off (avoids noise).
struct TagExportOptions {
    var includeFandom       = true
    var includeRelationship = true
    var includeCharacter    = true
    var includeCategory     = true   // from Calibre tags, via AO3TagKind.classify
    var includeRating       = true   // from Calibre tags, via AO3TagKind.classify
    var includeWarning      = true   // from Calibre tags, via AO3TagKind.classify
    var includeFreeform     = false  // AO3 "Additional Tags" — off by default
}

/// §3b: Assemble the tag list for one book using the selected categories.
/// Fandoms/relationships/characters come from AO3MetadataRecord (extracted fields).
/// Rating/warning/category come from Calibre's tag table, classified via AO3TagKind.
/// Because §2 gives those buckets their own dedicated CSV columns, the Tags column
/// in the CSV carries whatever subset the user has opted into — freeform by default off.
func filteredTagsForExport(book: CalibreBook,
                            ao3: AO3MetadataRecord?,
                            options: TagExportOptions) -> [String] {
    var result: [String] = []
    if options.includeFandom,       let ao3 { result += ao3.fandoms }
    if options.includeRelationship, let ao3 { result += ao3.relationships }
    if options.includeCharacter,    let ao3 { result += ao3.characters }
    if options.includeFreeform,     let ao3 { result += ao3.additionalTags }
    // Classify Calibre tags so we can separate rating/warning/category from freeform.
    let buckets = AO3TagBuckets.from(tags: book.tags)
    if options.includeCategory { result += buckets.categories }
    if options.includeRating   { result += buckets.ratings }
    if options.includeWarning  { result += buckets.warnings }
    return result
}

// MARK: - §2: ExportRow

/// Bundles a book with its enrichment data. Assembled once at the call site,
/// passed into CSV generation. No N+1 queries — data is bulk-fetched before building rows.
struct ExportRow {
    let book: CalibreBook
    let ao3: AO3MetadataRecord?
    let collectionNames: [String]       // all Ambrosia collections (system + user)
    let epubAbsolutePath: String?
}

// MARK: - §3: Filename ID source

enum ExportFilenameIDSource {
    /// Use AO3 work ID when present, fall back to Calibre ID.
    case ao3ThenCalibre
}

// MARK: - ExportManager

/// Exports a list of `CalibreBook` structs to a CSV or copies their EPUBs to a folder.
///
/// CSV rules (RFC 4180 compliant):
/// - First row is the header.
/// - Fields containing commas, double-quotes, or newlines are wrapped in double-quotes.
/// - Internal double-quotes are escaped by doubling: " → ""
/// - Newlines within fields are replaced with a space (keeps rows on one line).
struct ExportManager {

    // MARK: - §2: Enriched CSV

    /// Build the enriched CSV string from an array of `ExportRow` values.
    ///
    /// §2 columns (20 total):
    /// Title, Authors, Series, Tags (§3b filtered),
    /// Word Count (ao3 primary, book fallback), Kudos,
    /// Published Date (ao3 primary, Calibre fallback), Updated Date,
    /// Status (§5: Complete / Work in Progress / Unknown),
    /// Fandoms, Relationships, Characters, Additional Tags, Category,
    /// AO3 Collections, AO3 Series, Story URL, AO3 Work ID,
    /// Collections (all Ambrosia), File Location.
    static func exportToCSV(rows: [ExportRow],
                             tagOptions: TagExportOptions = TagExportOptions()) -> String {
        let header = [
            "Title", "Authors", "Series", "Tags",
            "Word Count", "Kudos",
            "Published Date", "Updated Date",
            "Status",
            "Fandoms", "Relationships", "Characters", "Additional Tags", "Category",
            "AO3 Collections", "AO3 Series", "Story URL", "AO3 Work ID",
            "Collections",
            "File Location"
        ]

        var csvRows: [[String]] = [header]

        for r in rows {
            let tags = filteredTagsForExport(book: r.book, ao3: r.ao3, options: tagOptions)
            csvRows.append([
                r.book.title,
                r.book.authors.joined(separator: "; "),
                r.book.displaySeries ?? "",
                tags.joined(separator: "; "),
                // §2a: ao3 word count is primary; Calibre custom column is fallback.
                (r.ao3?.wordCount ?? r.book.wordCount).map(String.init) ?? "",
                r.book.kudos.map(String.init) ?? "",
                r.ao3?.publishedDate ?? r.book.publishedDate.map { isoDate($0) } ?? "",
                r.ao3?.updatedDate ?? "",
                completionLabel(r.ao3),                              // §5 naming
                (r.ao3?.fandoms ?? []).joined(separator: "; "),
                (r.ao3?.relationships ?? []).joined(separator: "; "),
                (r.ao3?.characters ?? []).joined(separator: "; "),
                (r.ao3?.additionalTags ?? []).joined(separator: "; "),
                (r.ao3?.categories ?? []).joined(separator: "; "),
                (r.ao3?.ao3Collections ?? []).joined(separator: "; "),
                (r.ao3?.series ?? []).map(\.name).joined(separator: "; "),
                r.ao3?.storyURL ?? "",
                r.ao3?.workID ?? "",
                r.collectionNames.joined(separator: "; "),
                r.epubAbsolutePath ?? ""
            ])
        }

        return csvRows.map { csvRow($0) }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - §1: Present CSV export panel (enriched)

    /// Present an NSSavePanel and, if the user confirms, fetch all matching books,
    /// enrich with AO3 metadata and collection membership, then write the CSV.
    ///
    /// - Parameters:
    ///   - currentPageBooks: The currently displayed page (used only as a fallback
    ///     if `session` is unavailable; normally all matching books are fetched via §1).
    ///   - session: The active LibrarySession — used to bulk-fetch AO3 metadata
    ///     and collection membership.
    ///   - filterResult: The active FilterResult, whose calibreIDs drive fetchAllMatchingBooks.
    ///   - toolbarState: Provides sort/ascending and the active filter expression.
    @MainActor
    static func presentExportPanel(books currentPageBooks: [CalibreBook],
                                   session: LibrarySession? = nil,
                                   filterResult: FilterResult? = nil,
                                   toolbarState: LibraryToolbarState? = nil,
                                   tagOptions: TagExportOptions = TagExportOptions()) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Ambrosia Export.csv"
        panel.message = "Choose a location to save the CSV export."
        panel.prompt  = "Export"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let rows = await buildExportRows(
                    currentPageBooks: currentPageBooks,
                    session: session,
                    filterResult: filterResult,
                    toolbarState: toolbarState
                )
                let csv = exportToCSV(rows: rows, tagOptions: tagOptions)
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - §1: Build ExportRows (bulk fetch, no N+1)

    @MainActor
    static func buildExportRows(currentPageBooks: [CalibreBook],
                                 session: LibrarySession?,
                                 filterResult: FilterResult?,
                                 toolbarState: LibraryToolbarState?) async -> [ExportRow] {
        guard let session, let library = session.library else {
            // Fallback: export current page only, no enrichment
            return currentPageBooks.map { ExportRow(book: $0, ao3: nil, collectionNames: [], epubAbsolutePath: nil) }
        }

        // §1: Fetch all matching books (no pagination), respecting active filter + search.
        let sort = toolbarState?.sortField ?? .title
        let ascending = toolbarState?.ascending ?? true
        let query: SearchQuery
        if let text = toolbarState?.searchText, !text.isEmpty {
            query = SearchQueryParser.parse(text)
        } else {
            query = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        }
        // SQL-backed filters (e.g. NOT-tag rules) resolve via the FilterExpression itself,
        // not a pre-resolved ID list — calibreIDs is expected to be empty in that case.
        // Only collapse to "no ID restriction" when there's genuinely no active filter.
        let restrictIDs: [Int]? = filterResult.flatMap { result in
            result.isSQLBacked ? nil : (result.calibreIDs.isEmpty ? nil : result.calibreIDs)
        }
        let activeFilter: FilterExpression? = {
            guard let result = filterResult, result.isSQLBacked else { return nil }
            return toolbarState?.filterExpression
        }()

        let books = await library.fetchAllMatchingBooks(
            ids: restrictIDs,
            query: query,
            filter: activeFilter,
            sort: sort,
            ascending: ascending
        )

        // §2: Bulk-fetch AO3 metadata and collection membership (not per-book).
        // Sequential awaits on actor-isolated methods; optional-chain async-let
        // has implicit sendability issues in Swift 5.10+.
        let ids = books.map(\.id)
        let ao3Map: [Int: AO3MetadataRecord]
        if let metaDB = session.metaDB {
            ao3Map = (try? await metaDB.ao3Metadata(for: ids)) ?? [:]
        } else {
            ao3Map = [:]
        }
        let membershipByCollectionID: [String: Set<Int>]
        let allCollections: [CollectionRow]
        if let cs = session.collectionStore {
            membershipByCollectionID = (try? await cs.membershipByCollectionID()) ?? [:]
            allCollections = (try? await cs.collections()) ?? []
        } else {
            membershipByCollectionID = [:]
            allCollections = []
        }
        let nameByID = Dictionary(uniqueKeysWithValues: allCollections.map { ($0.id, $0.name) })

        // Invert: collectionID → Set<calibreID>  ⟹  calibreID → [collectionName]
        // Includes ALL collections (system + user-created) per plan decision.
        var collectionsForBook: [Int: [String]] = [:]
        for (collectionID, memberIDs) in membershipByCollectionID {
            guard let name = nameByID[collectionID] else { continue }
            for calibreID in memberIDs {
                collectionsForBook[calibreID, default: []].append(name)
            }
        }
        // Sort each book's collection list for stable CSV output
        for key in collectionsForBook.keys {
            collectionsForBook[key]?.sort()
        }

        let libraryRoot = library.root

        return books.map { book in
            let ao3 = ao3Map[book.id]
            let epubPath = book.epubURL(libraryRoot: libraryRoot)?.path
            let collections = collectionsForBook[book.id] ?? []
            return ExportRow(book: book, ao3: ao3, collectionNames: collections,
                             epubAbsolutePath: epubPath)
        }
    }

    // MARK: - §3: EPUB folder export (async, with progress)

    /// Copy EPUBs to `destination` and call `progress` after each file.
    /// Returns (copied, skippedTitles) when done. `copied` counts distinct books
    /// successfully copied at least once, not the total number of file-copy
    /// operations — a multi-series book copied into three series folders still
    /// counts as one toward `copied`.
    static func exportEPUBs(
        books: [CalibreBook],
        libraryRoot: URL,
        destination: URL,
        ao3Map: [Int: AO3MetadataRecord],
        groupBySeries: Bool,
        seriesEntries: [Int: [SeriesCacheEntry]] = [:],
        filenameIDSource: ExportFilenameIDSource = .ao3ThenCalibre,
        progress: @Sendable @escaping (Int) -> Void
    ) async -> (copied: Int, skipped: [String]) {
        await Task.detached(priority: .userInitiated) {
            var copied = 0
            var skipped: [String] = []

            for book in books {
                guard let source = book.epubURL(libraryRoot: libraryRoot) else {
                    skipped.append(book.displayTitle); progress(copied + skipped.count); continue
                }
                let targetFolders: [(url: URL, seriesIndex: Int)]
                if groupBySeries, let entries = seriesEntries[book.id], !entries.isEmpty {
                    // A book that's a member of more than one series (e.g. #1 of A and
                    // #3 of B) gets copied into every one of its series' folders, not
                    // just the first. Folder name includes the series id (AO3 id, else
                    // Calibre series id) so two distinct series sharing a display name
                    // don't collide into the same export folder (bug #3). Dedup on the
                    // resulting folder name regardless, in case two entries somehow
                    // still resolve to the same one.
                    var seenFolderNames = Set<String>()
                    targetFolders = entries.compactMap { entry -> (URL, Int)? in
                        let sanitizedName = CalibreBook.sanitizedForFilename(entry.seriesName)
                        let idSuffix = entry.ao3SeriesID ?? entry.calibreSeriesID.map(String.init) ?? ""
                        let folderName = idSuffix.isEmpty ? sanitizedName : "\(sanitizedName)-\(idSuffix)"
                        guard seenFolderNames.insert(folderName).inserted else { return nil }
                        return (destination.appendingPathComponent(folderName), entry.seriesIndex)
                    }
                } else {
                    // seriesIndex is never read here: seriesIndexPrefix passed to
                    // exportFilename below is gated on groupBySeries, and per bug #3
                    // touch point 9, the prefix only applies within series-grouped
                    // export folders — ungrouped/single-book export is unaffected.
                    targetFolders = [(destination, 0)]
                }

                var copiedThisBook = false
                for targetFolder in targetFolders {
                    // Filename is computed per folder, not hoisted once outside this
                    // loop: a book's index differs across series (#1 of A and #3 of
                    // B), so the zero-padded prefix must match the specific folder
                    // it's being copied into (bug #3, touch point 10).
                    let filename = book.exportFilename(
                        ao3: ao3Map[book.id],
                        idSource: filenameIDSource,
                        seriesIndexPrefix: groupBySeries ? targetFolder.seriesIndex : nil
                    )
                    try? FileManager.default.createDirectory(at: targetFolder.url, withIntermediateDirectories: true)
                    let dest = uniqueDestination(for: filename, in: targetFolder.url)
                    do {
                        try FileManager.default.copyItem(at: source, to: dest)
                        copiedThisBook = true
                    } catch {
                        // Continue attempting the remaining folders for this book even
                        // if one copy fails; only count as skipped if none succeeded.
                    }
                }
                if copiedThisBook {
                    copied += 1
                } else {
                    skipped.append(book.displayTitle)
                }
                progress(copied + skipped.count)
            }
            return (copied, skipped)
        }.value
    }

    /// Exports at or above this count trigger a confirmation alert before any
    /// file I/O begins, since the folder-choice moment is the last point the
    /// user can cheaply back out before the copy loop runs to completion.
    static let largeExportThreshold = 1000

    /// Present a folder picker and copy all matching EPUBs into the chosen directory.
    /// Files are renamed using exportFilename() (§3). Collisions are resolved with -2, -3, …
    /// Delegates to `exportEPUBs` for the actual copy logic so the series-duplication
    /// behavior (a multi-series book copied into every one of its series' folders)
    /// only needs to be implemented and tested in one place.
    @MainActor
    static func presentEPUBExportPanel(books: [CalibreBook],
                                        libraryRoot: URL,
                                        ao3Map: [Int: AO3MetadataRecord],
                                        groupBySeries: Bool = false,
                                        seriesEntries: [Int: [SeriesCacheEntry]] = [:],
                                        filenameIDSource: ExportFilenameIDSource = .ao3ThenCalibre) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder to copy \(books.count) EPUB\(books.count == 1 ? "" : "s") into."

        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }

            if books.count >= largeExportThreshold {
                let confirm = NSAlert()
                confirm.messageText = "Export \(books.count) EPUBs?"
                confirm.informativeText = "This will copy \(books.count) files to \"\(destination.lastPathComponent)\" and may take a while."
                confirm.addButton(withTitle: "Export")
                confirm.addButton(withTitle: "Cancel")
                confirm.alertStyle = .warning
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }

            Task {
                let (copied, skipped) = await exportEPUBs(
                    books: books,
                    libraryRoot: libraryRoot,
                    destination: destination,
                    ao3Map: ao3Map,
                    groupBySeries: groupBySeries,
                    seriesEntries: seriesEntries,
                    filenameIDSource: filenameIDSource,
                    progress: { _ in }
                )
                presentEPUBExportSummary(copied: copied, skipped: skipped)
            }
        }
    }

    /// §3: Unique destination — appends -2, -3, … to the stem to avoid overwriting.
    static func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let ext  = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(filename)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }

    @MainActor
    static func presentEPUBExportSummary(copied: Int, skipped: [String]) {
        let alert = NSAlert()
        if skipped.isEmpty {
            alert.messageText = "Export Complete"
            alert.informativeText = "Copied \(copied) EPUB\(copied == 1 ? "" : "s")."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Export Finished with Warnings"
            let skippedList = skipped.prefix(10).joined(separator: "\n")
            let more = skipped.count > 10 ? "\n… and \(skipped.count - 10) more." : ""
            alert.informativeText = "Copied \(copied) EPUB\(copied == 1 ? "" : "s").\n\nCould not copy:\n\(skippedList)\(more)"
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    // MARK: - Helpers

    /// ISO date string for a Date value (yyyy-MM-dd).
    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// §5: Map AO3 completion state to a human-readable string using the new case names.
    private static func completionLabel(_ ao3: AO3MetadataRecord?) -> String {
        guard let ao3 else { return "Unknown" }
        if ao3.isComplete { return AO3CompletionStatus.complete.rawValue }
        return AO3CompletionStatus.workInProgress.rawValue
    }

    /// Encode a single CSV row. Each field is escaped individually.
    private static func csvRow(_ fields: [String]) -> String {
        fields.map { csvEscape($0) }.joined(separator: ",")
    }

    /// Escape a single field per RFC 4180.
    private static func csvEscape(_ field: String) -> String {
        let sanitised = field
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n",   with: " ")
            .replacingOccurrences(of: "\r",   with: " ")
        let needsQuoting = sanitised.contains(",") || sanitised.contains("\"")
        if needsQuoting {
            let escaped = sanitised.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return sanitised
    }
}

// MARK: - §3: CalibreBook filename helpers

extension CalibreBook {

    /// §3: Produce a filesystem-safe EPUB filename.
    /// Format: "<index-prefix><sanitised-title>-<id>.epub"
    /// ID: AO3 work ID when available; Calibre ID as fallback.
    /// `seriesIndexPrefix`, when present, is zero-padded to 2 digits and
    /// prepended (e.g. "01 - Title-12345.epub") — used only within
    /// series-grouped export folders (bug #3); ungrouped/single-book export
    /// passes `nil` and is unaffected.
    func exportFilename(ao3: AO3MetadataRecord?,
                        idSource: ExportFilenameIDSource = .ao3ThenCalibre,
                        seriesIndexPrefix: Int? = nil) -> String {
        let base = Self.sanitizedForFilename(displayTitle)
        let suffix = ao3?.workID ?? String(id)
        let prefix = seriesIndexPrefix.map { String(format: "%02d - ", $0) } ?? ""
        return "\(prefix)\(base)-\(suffix).epub"
    }

    /// Strip characters that are illegal or problematic in macOS filenames.
    /// Truncates to 120 characters to stay well under HFS+ limits.
    static func sanitizedForFilename(_ raw: String) -> String {
        // Characters forbidden in macOS filenames (HFS+): / and NUL.
        // We also strip characters that cause problems cross-platform or in shells.
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of whitespace
        let collapsed = cleaned.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Truncate — String.prefix returns a Substring; convert to String
        return String(collapsed.prefix(120))
    }
}
