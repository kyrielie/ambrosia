// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Observation

// MARK: - Tabs & Filters

enum LibraryHealthTab: String, CaseIterable, Identifiable {
    case duplicates = "Duplicates"
    case staleWIPs = "Stale WIPs"
    case seriesGaps = "Series Gaps"
    case seriesSequels = "Series Sequels"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .duplicates: return "doc.on.doc"
        case .staleWIPs: return "clock.badge.exclamationmark"
        case .seriesGaps: return "list.number"
        case .seriesSequels: return "sparkles.rectangle.stack"
        }
    }
}

enum DuplicateFilter: String, CaseIterable, Identifiable {
    case all = "True Duplicates"
    case exactSHA = "Exact File (SHA-256)"
    case contentZIP = "Same Content (ZIP)"
    case differentEdition = "Different Editions"

    var id: String { rawValue }
}

enum WIPAgeFilter: String, CaseIterable, Identifiable {
    case all = "All WIPs"
    case underOneMonth = "< 1 Month"
    case underThreeMonths = "< 3 Months"
    case underSixMonths = "< 6 Months"
    case underOneYear = "< 1 Year"
    case overSixMonths = "> 6 Months"
    case overOneYear = "> 1 Year"
    case overTwoYears = "> 2 Years"

    var id: String { rawValue }

    func matches(date: Date?, now: Date = Date()) -> Bool {
        if self == .all { return true }
        guard let date else { return false }
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        switch self {
        case .all: return true
        case .underOneMonth: return days < 30
        case .underThreeMonths: return days < 90
        case .underSixMonths: return days < 180
        case .underOneYear: return days < 365
        case .overSixMonths: return days >= 180
        case .overOneYear: return days >= 365
        case .overTwoYears: return days >= 730
        }
    }
}

enum WIPDateBasis: String, CaseIterable, Identifiable {
    case ao3Updated = "AO3 Updated"
    case calibreDateAdded = "Date Added"

    var id: String { rawValue }
}

enum SeriesGapFilter: String, CaseIterable, Identifiable {
    case all = "All Gaps"
    case infixOnly = "Infix Gaps"
    case prefixOnly = "Prefix Gaps"

    var id: String { rawValue }
}

// MARK: - Models

struct StaleWIPItem: Identifiable {
    var id: Int { calibreID }
    let calibreID: Int
    let workID: String?
    let title: String
    let authors: [String]
    let chapterCurrent: Int?
    let chapterTotal: Int?
    let wordCount: Int?
    let updatedDate: Date?
    let publishedDate: Date?
    let dateAdded: Date?
    let isSkipped: Bool
    let isReadLater: Bool
    let readPercent: Double
    var isDismissed: Bool
}

struct UnlinkedSeriesItem: Identifiable {
    var id: Int { calibreID }
    let calibreID: Int
    let title: String
    let authors: [String]
    let seriesEntries: [AO3MetadataRecord.SeriesEntry]
}

struct SequelCheckSeriesItem: Identifiable {
    var id: String { seriesKey }
    let seriesKey: String
    let seriesName: String
    let ao3SeriesID: String
    let authors: [String]
    let presentCount: Int
    let latestTitle: String
    let isLatestComplete: Bool
    let isFinishedReading: Bool
    var isDismissed: Bool
}

// MARK: - View Model

@Observable
@MainActor
final class LibraryHealthViewModel {
    var selectedTab: LibraryHealthTab = .duplicates
    var isLoading = false
    var isVerifyingExactDuplicates = false
    var isTrashing = false
    var statusMessage: String?

    // Duplicates
    var clusters: [AO3DuplicateCluster] = []
    var duplicateFilter: DuplicateFilter = .all
    var duplicateSearchText = ""
    var migratedClusterIDs: Set<String> = []
    var verificationComplete = false

    // Stale WIPs
    var staleWIPs: [StaleWIPItem] = []
    var wipAgeFilter: WIPAgeFilter = .overOneYear
    var wipDateBasis: WIPDateBasis = .ao3Updated
    var wipSearchText = ""
    var wipHideSkipped = true
    var wipOnlyStartedOrReadLater = false
    var wipShowDismissed = false

    // Series Gaps
    var gapReports: [SeriesGapReport] = []
    var gapFilter: SeriesGapFilter = .all
    var gapSearchText = ""

    // Series Sequels
    var unlinkedSeriesItems: [UnlinkedSeriesItem] = []
    var sequelCheckItems: [SequelCheckSeriesItem] = []
    var sequelSearchText = ""
    var sequelShowDismissed = false

    private var lastLoadedPath: String?
    private var verificationTask: Task<Void, Never>?

    static let dismissalKindWIP = "stale_wip"
    static let dismissalKindSequel = "series_sequel"

    // MARK: - Filtered Collections

    var filteredClusters: [AO3DuplicateCluster] {
        let query = duplicateSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clusters.filter { cluster in
            if !query.isEmpty {
                let matchesTitle = cluster.title.lowercased().contains(query)
                let matchesAuthor = cluster.entries.contains {
                    $0.authors.joined(separator: " ").lowercased().contains(query)
                }
                let matchesWork = cluster.workID.lowercased().contains(query)
                if !matchesTitle && !matchesAuthor && !matchesWork { return false }
            }
            switch duplicateFilter {
            case .all:
                return true
            case .exactSHA:
                return cluster.loserEntries.contains { $0.matchTier == .exactFileMatch }
            case .contentZIP:
                return cluster.loserEntries.contains { $0.matchTier == .contentMatch }
            case .differentEdition:
                return cluster.loserEntries.contains {
                    $0.matchTier == nil || $0.matchTier == .differentEdition
                }
            }
        }
    }

    var exactMatchLoserCount: Int {
        clusters.flatMap(\.loserEntries).filter { $0.matchTier == .exactFileMatch }.count
    }

    var contentMatchLoserCount: Int {
        clusters.flatMap(\.loserEntries).filter { $0.matchTier == .contentMatch }.count
    }

    var reclaimableExactBytes: Int64 {
        clusters.flatMap(\.loserEntries)
            .filter { $0.matchTier == .exactFileMatch }
            .compactMap(\.fileSizeBytes)
            .reduce(0, +)
    }

    var filteredWIPs: [StaleWIPItem] {
        let now = Date()
        let query = wipSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return staleWIPs.filter { item in
            if !wipShowDismissed && item.isDismissed { return false }
            if wipHideSkipped && item.isSkipped { return false }
            if wipOnlyStartedOrReadLater && !(item.isReadLater || item.readPercent > 0) { return false }
            let refDate: Date? = wipDateBasis == .ao3Updated
                ? (item.updatedDate ?? item.publishedDate)
                : item.dateAdded
            if !wipAgeFilter.matches(date: refDate, now: now) { return false }
            if !query.isEmpty {
                let titleMatch = item.title.lowercased().contains(query)
                let authorMatch = item.authors.joined(separator: " ").lowercased().contains(query)
                if !titleMatch && !authorMatch { return false }
            }
            return true
        }
    }

    var filteredGapReports: [SeriesGapReport] {
        let query = gapSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return gapReports.filter { report in
            switch gapFilter {
            case .all:
                break
            case .infixOnly:
                let minPresent = report.presentIndices.min() ?? 1
                if !report.missingIndices.contains(where: { $0 > minPresent }) { return false }
            case .prefixOnly:
                let minPresent = report.presentIndices.min() ?? 1
                if !report.missingIndices.contains(where: { $0 < minPresent }) { return false }
            }
            if !query.isEmpty {
                let nameMatch = report.seriesName.lowercased().contains(query)
                let authorMatch = report.authors.joined(separator: " ").lowercased().contains(query)
                if !nameMatch && !authorMatch { return false }
            }
            return true
        }
    }

    var filteredUnlinkedSeries: [UnlinkedSeriesItem] {
        let query = sequelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return unlinkedSeriesItems }
        return unlinkedSeriesItems.filter { item in
            item.title.lowercased().contains(query)
                || item.authors.joined(separator: " ").lowercased().contains(query)
                || item.seriesEntries.contains { $0.name.lowercased().contains(query) }
        }
    }

    var filteredSequelChecks: [SequelCheckSeriesItem] {
        let query = sequelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sequelCheckItems.filter { item in
            if !sequelShowDismissed && item.isDismissed { return false }
            if !query.isEmpty {
                let nameMatch = item.seriesName.lowercased().contains(query)
                let authorMatch = item.authors.joined(separator: " ").lowercased().contains(query)
                if !nameMatch && !authorMatch { return false }
            }
            return true
        }
    }

    // MARK: - Loading

    func loadIfNeeded(session: LibrarySession) async {
        if lastLoadedPath == session.activePath && !isLoading && !clusters.isEmpty {
            return
        }
        await reload(session: session)
    }

    func reload(session: LibrarySession) async {
        verificationTask?.cancel()
        lastLoadedPath = session.activePath
        isLoading = true
        verificationComplete = false
        statusMessage = nil

        guard let metaDB = session.metaDB, let library = session.library else {
            clusters = []
            staleWIPs = []
            gapReports = []
            unlinkedSeriesItems = []
            sequelCheckItems = []
            isLoading = false
            return
        }

        async let snapshotsTask = metaDB.allAO3HealthSnapshots()
        async let cacheAnthologiesTask = metaDB.allAnthologyCacheIDs()
        async let commentAnthologiesTask = library.anthologyBookIDs()
        async let calibreSeriesBookIDsTask = library.fetchCalibreSeriesBookIDs()
        async let wipDismissalsTask = metaDB.dismissedMaintenanceKeys(kind: Self.dismissalKindWIP)
        async let sequelDismissalsTask = metaDB.dismissedMaintenanceKeys(kind: Self.dismissalKindSequel)

        let snapshots = await snapshotsTask
        let anthologyIDs = await cacheAnthologiesTask.union(commentAnthologiesTask)
        let calibreSeriesBookIDs = await calibreSeriesBookIDsTask
        let wipDismissals = await wipDismissalsTask
        let sequelDismissals = await sequelDismissalsTask

        // 1. Build Duplicates
        await loadDuplicates(
            snapshots: snapshots,
            anthologyIDs: anthologyIDs,
            library: library,
            metaDB: metaDB
        )

        // 2. Build Stale WIPs
        await loadStaleWIPs(
            snapshots: snapshots,
            wipDismissals: wipDismissals,
            session: session,
            library: library,
            metaDB: metaDB
        )

        // 3. Build Series Gaps & Sequels
        await loadSeriesHealth(
            snapshots: snapshots,
            anthologyIDs: anthologyIDs,
            calibreSeriesBookIDs: calibreSeriesBookIDs,
            sequelDismissals: sequelDismissals,
            session: session
        )

        isLoading = false
        startExactDuplicateVerification(session: session)
    }

    private func loadDuplicates(
        snapshots: [AmbrosiaMetaDB.AO3HealthSnapshot],
        anthologyIDs: Set<Int>,
        library: CalibreLibrary,
        metaDB: AmbrosiaMetaDB
    ) async {
        var workIDs: [Int: String] = [:]
        var dates: [Int: (published: String?, updated: String?)] = [:]
        for snap in snapshots {
            if let wid = snap.workID, !wid.isEmpty {
                workIDs[snap.calibreID] = wid
            }
            dates[snap.calibreID] = (snap.publishedDate, snap.updatedDate)
        }

        let grouped = Dictionary(grouping: workIDs.keys, by: { workIDs[$0] ?? "" })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
        let candidateIDs = grouped.values.flatMap { $0 }.filter { !anthologyIDs.contains($0) }

        guard !candidateIDs.isEmpty else {
            clusters = []
            return
        }

        let books = await library.booksForIDs(candidateIDs)
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let metaByID = (try? await metaDB.ao3Metadata(for: candidateIDs)) ?? [:]
        let statesByID = await metaDB.bookStates(for: candidateIDs)
        let datesAdded = await library.fetchDateAdded(for: candidateIDs)

        var annotationsByID: [Int: Int] = [:]
        for id in candidateIDs {
            if let count = try? await metaDB.annotations(for: id).count, count > 0 {
                annotationsByID[id] = count
            }
        }

        clusters = CalibreDuplicateManager.buildClusters(
            workIDs: workIDs,
            dates: dates,
            booksByID: booksByID,
            metadataByID: metaByID,
            bookStatesByID: statesByID,
            annotationCountsByID: annotationsByID,
            anthologyIDs: anthologyIDs,
            datesAdded: datesAdded
        )
    }

    private func loadStaleWIPs(
        snapshots: [AmbrosiaMetaDB.AO3HealthSnapshot],
        wipDismissals: Set<String>,
        session: LibrarySession,
        library: CalibreLibrary,
        metaDB: AmbrosiaMetaDB
    ) async {
        let wipSnaps = snapshots.filter { $0.isComplete == false }
        let wipIDs = wipSnaps.map(\.calibreID)
        guard !wipIDs.isEmpty else {
            staleWIPs = []
            return
        }

        let books = await library.booksForIDs(wipIDs)
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let datesAdded = await library.fetchDateAdded(for: wipIDs)
        let statesByID = await metaDB.bookStates(for: wipIDs)
        let skippedIDs = await metaDB.effectiveCollectionBookIDs(collectionID: SystemCollectionID.skipped)
        let readLaterIDs = session.effectiveReadLaterIDs

        var items: [StaleWIPItem] = []
        items.reserveCapacity(wipSnaps.count)
        for snap in wipSnaps {
            guard let book = booksByID[snap.calibreID] else { continue }
            let upd = snap.updatedDate.flatMap { parseISODate($0) }
            let pub = snap.publishedDate.flatMap { parseISODate($0) }
            items.append(StaleWIPItem(
                calibreID: snap.calibreID,
                workID: snap.workID,
                title: book.displayTitle,
                authors: book.authors,
                chapterCurrent: snap.chapterCurrent,
                chapterTotal: snap.chapterTotal,
                wordCount: snap.wordCount ?? book.wordCount,
                updatedDate: upd,
                publishedDate: pub,
                dateAdded: datesAdded[snap.calibreID],
                isSkipped: skippedIDs.contains(snap.calibreID),
                isReadLater: readLaterIDs.contains(snap.calibreID),
                readPercent: statesByID[snap.calibreID]?.totalReadPercent ?? 0,
                isDismissed: wipDismissals.contains("\(snap.calibreID)")
            ))
        }
        items.sort { ($0.updatedDate ?? $0.publishedDate ?? .distantPast) < ($1.updatedDate ?? $1.publishedDate ?? .distantPast) }
        staleWIPs = items
    }

    private func loadSeriesHealth(
        snapshots: [AmbrosiaMetaDB.AO3HealthSnapshot],
        anthologyIDs: Set<Int>,
        calibreSeriesBookIDs: Set<Int>,
        sequelDismissals: Set<String>,
        session: LibrarySession
    ) async {
        guard let library = session.library, let metaDB = session.metaDB else { return }
        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.calibreID, $0) })
        // Unlinked local series
        let unlinkedSnaps = snapshots.filter { !$0.series.isEmpty && !calibreSeriesBookIDs.contains($0.calibreID) }
        let unlinkedIDs = unlinkedSnaps.map(\.calibreID)
        let unlinkedBooks = unlinkedIDs.isEmpty ? [] : await library.booksForIDs(unlinkedIDs)
        let unlinkedByID = Dictionary(uniqueKeysWithValues: unlinkedBooks.map { ($0.id, $0) })
        unlinkedSeriesItems = unlinkedSnaps.compactMap { snap in
            guard let book = unlinkedByID[snap.calibreID] else { return nil }
            return UnlinkedSeriesItem(
                calibreID: snap.calibreID,
                title: book.displayTitle,
                authors: book.authors,
                seriesEntries: snap.series
            )
        }

        // Series gaps & sequel queue
        let allEntries = await metaDB.allSeriesCacheEntries()
        let allSeriesIDs = Array(Set(allEntries.map(\.calibreID)))
        guard !allSeriesIDs.isEmpty else {
            gapReports = []
            sequelCheckItems = []
            return
        }

        let seriesBooks = await library.booksForIDs(allSeriesIDs)
        let booksByID = Dictionary(uniqueKeysWithValues: seriesBooks.map { ($0.id, $0) })
        let metaByID = (try? await metaDB.ao3Metadata(for: allSeriesIDs)) ?? [:]
        let statesByID = await metaDB.bookStates(for: allSeriesIDs)
        let duplicateLoserIDs = await library.duplicateLoserBookIDs()
        let finishedIDs = await metaDB.effectiveCollectionBookIDs(collectionID: SystemCollectionID.finished)
        let groups = buildSeriesGroups(
            allEntries: allEntries,
            byID: booksByID,
            seriesMetadata: metaByID,
            anthologyIDs: anthologyIDs,
            duplicateLoserIDs: duplicateLoserIDs
        )

        var reports: [SeriesGapReport] = []
        var sequels: [SequelCheckSeriesItem] = []

        for (_, group) in groups {
            let report = SeriesGapAnalyzer.analyze(series: group, metadataByID: metaByID)
            if !report.missingIndices.isEmpty {
                reports.append(report)
            }
            if let ao3SID = report.ao3SeriesID, !ao3SID.isEmpty, let latestWork = group.works.last {
                let latestSnap = snapshotByID[latestWork.id]
                let isComplete = latestSnap?.isComplete ?? false
                let isFinished = (statesByID[latestWork.id]?.totalReadPercent ?? 0) >= 0.9
                    || finishedIDs.contains(latestWork.id)
                if isComplete || isFinished {
                    sequels.append(SequelCheckSeriesItem(
                        seriesKey: group.seriesKey,
                        seriesName: group.seriesName,
                        ao3SeriesID: ao3SID,
                        authors: group.allAuthors,
                        presentCount: group.works.count,
                        latestTitle: latestWork.displayTitle,
                        isLatestComplete: isComplete,
                        isFinishedReading: isFinished,
                        isDismissed: sequelDismissals.contains(group.seriesKey)
                    ))
                }
            }
        }

        gapReports = reports.sorted { $0.coverageFraction > $1.coverageFraction }
        sequelCheckItems = sequels.sorted { $0.seriesName.localizedCaseInsensitiveCompare($1.seriesName) == .orderedAscending }
    }

    // MARK: - Exact Duplicate Verification

    func startExactDuplicateVerification(session: LibrarySession) {
        verificationTask?.cancel()
        guard let libraryRoot = session.activeURL,
              let library = session.library,
              !clusters.isEmpty else {
            verificationComplete = true
            return
        }

        isVerifyingExactDuplicates = true
        let snapshotClusters = clusters
        verificationTask = Task { [weak self] in
            var updatedClusters = snapshotClusters
            for idx in updatedClusters.indices {
                if Task.isCancelled { return }
                let cluster = updatedClusters[idx]
                let winnerID = cluster.winnerID
                let loserIDs = cluster.loserIDs
                let allIDs = [winnerID] + loserIDs

                var urls: [Int: URL] = [:]
                for id in allIDs {
                    if let url = await library.epubURL(calibreID: id) {
                        urls[id] = url
                    } else if let rel = cluster.entries.first(where: { $0.calibreID == id })?.epubPath {
                        let fallback = libraryRoot.appendingPathComponent(rel)
                        if FileManager.default.fileExists(atPath: fallback.path) {
                            urls[id] = fallback
                        }
                    }
                }

                let winnerURL = urls[winnerID]
                let loserURLMap = Dictionary(uniqueKeysWithValues: loserIDs.map { ($0, urls[$0]) })
                let verified = await Task.detached(priority: .utility) {
                    let tiers = DuplicateVerificationService.verifyCluster(
                        winnerURL: winnerURL,
                        loserURLs: loserURLMap
                    )
                    var sizes: [Int: Int64] = [:]
                    for (id, url) in urls {
                        if let sz = DuplicateVerificationService.fileSize(of: url) {
                            sizes[id] = sz
                        }
                    }
                    return (tiers, sizes)
                }.value

                if Task.isCancelled { return }

                let newEntries = cluster.entries.map { entry -> AO3DuplicateEntry in
                    var copy = entry
                    copy.fileSizeBytes = verified.1[entry.calibreID]
                    if !entry.isWinner {
                        copy.matchTier = verified.0[entry.calibreID]
                    }
                    return copy
                }
                updatedClusters[idx] = AO3DuplicateCluster(
                    workID: cluster.workID,
                    title: cluster.title,
                    winnerID: cluster.winnerID,
                    loserIDs: cluster.loserIDs,
                    entries: newEntries
                )
            }

            guard let self, !Task.isCancelled else { return }
            self.clusters = updatedClusters
            self.isVerifyingExactDuplicates = false
            self.verificationComplete = true
        }
    }

    // MARK: - Actions

    func setWinner(clusterID: String, newWinnerID: Int, session: LibrarySession) {
        guard let idx = clusters.firstIndex(where: { $0.workID == clusterID }) else { return }
        clusters[idx] = clusters[idx].withWinner(newWinnerID)
        statusMessage = "Set Calibre ID #\(newWinnerID) as preferred winner."
        startExactDuplicateVerification(session: session)
    }

    func migrateCluster(_ cluster: AO3DuplicateCluster, session: LibrarySession) {
        guard let metaDB = session.metaDB else { return }
        Task {
            do {
                for loserID in cluster.loserIDs {
                    try await metaDB.transferBookState(fromLoserID: loserID, toWinnerID: cluster.winnerID)
                }
                migratedClusterIDs.insert(cluster.workID)
                statusMessage = "Migrated state for \"\(cluster.title)\"."
            } catch {
                statusMessage = "Migration failed: \(error.localizedDescription)"
            }
        }
    }

    func prepareSafeRemovalCommand(includeContentMatches: Bool, session: LibrarySession) -> String {
        let targetTiers: Set<DuplicateMatchTier> = includeContentMatches
            ? [.exactFileMatch, .contentMatch]
            : [.exactFileMatch]
        let targetIDs = clusters.flatMap { cluster in
            cluster.loserEntries
                .filter { entry in entry.matchTier.map { targetTiers.contains($0) } ?? false }
                .map(\.calibreID)
        }
        return CalibreDuplicateManager.calibrePruneCLICommand(
            loserIDs: targetIDs,
            libraryPath: session.activePath
        )
    }

    func migrateExactDuplicates(includeContentMatches: Bool, session: LibrarySession) async -> Int {
        guard let metaDB = session.metaDB else { return 0 }
        let targetTiers: Set<DuplicateMatchTier> = includeContentMatches
            ? [.exactFileMatch, .contentMatch]
            : [.exactFileMatch]
        var migratedCount = 0
        for cluster in clusters {
            let matchingLosers = cluster.loserEntries.filter { entry in
                entry.matchTier.map { targetTiers.contains($0) } ?? false
            }
            guard !matchingLosers.isEmpty else { continue }
            for loser in matchingLosers {
                try? await metaDB.transferBookState(fromLoserID: loser.calibreID, toWinnerID: cluster.winnerID)
                migratedCount += 1
            }
            migratedClusterIDs.insert(cluster.workID)
        }
        return migratedCount
    }

    func predictedTrashDestination(session: LibrarySession) -> TrashDestination {
        guard let activePath = session.activePath else { return .macOSTrash }
        return CalibreTrashManager.predictedDestination(for: URL(fileURLWithPath: activePath))
    }

    func trashExactDuplicates(includeContentMatches: Bool, session: LibrarySession) async {
        guard !isTrashing else { return }
        let targetTiers: Set<DuplicateMatchTier> = includeContentMatches
            ? [.exactFileMatch, .contentMatch]
            : [.exactFileMatch]
        var winnerByLoserID: [Int: Int] = [:]
        var loserIDs: [Int] = []
        for cluster in clusters {
            for entry in cluster.loserEntries {
                if let tier = entry.matchTier, targetTiers.contains(tier) {
                    winnerByLoserID[entry.calibreID] = cluster.winnerID
                    loserIDs.append(entry.calibreID)
                }
            }
        }
        guard !loserIDs.isEmpty else { return }

        isTrashing = true
        defer { isTrashing = false }
        do {
            let result = try await CalibreTrashManager.trashBooks(
                winnerByLoserID: winnerByLoserID,
                loserIDs: loserIDs,
                session: session
            )
            let mb = String(format: "%.2f", Double(result.reclaimedBytes) / (1024 * 1024))
            statusMessage = "Moved \(result.trashedIDs.count) duplicate(s) (\(mb) MB) to \(result.destination.displayName)."
            await reload(session: session)
        } catch {
            statusMessage = "Trash failed: \(error.localizedDescription)"
        }
    }

    func trashSupersededEntry(
        entry: AO3DuplicateEntry,
        cluster: AO3DuplicateCluster,
        session: LibrarySession
    ) async {
        guard !isTrashing, !entry.isWinner else { return }
        isTrashing = true
        defer { isTrashing = false }
        do {
            let result = try await CalibreTrashManager.trashBooks(
                winnerByLoserID: [entry.calibreID: cluster.winnerID],
                loserIDs: [entry.calibreID],
                session: session
            )
            statusMessage = "Moved #\(entry.calibreID) to \(result.destination.displayName) and migrated state to #\(cluster.winnerID)."
            await reload(session: session)
        } catch {
            statusMessage = "Trash failed: \(error.localizedDescription)"
        }
    }

    func toggleDismissWIP(_ item: StaleWIPItem, session: LibrarySession) {
        guard let metaDB = session.metaDB else { return }
        let key = "\(item.calibreID)"
        Task {
            if item.isDismissed {
                try? await metaDB.undismissMaintenanceItem(kind: Self.dismissalKindWIP, targetKey: key)
            } else {
                try? await metaDB.dismissMaintenanceItem(kind: Self.dismissalKindWIP, targetKey: key)
            }
            if let idx = staleWIPs.firstIndex(where: { $0.calibreID == item.calibreID }) {
                staleWIPs[idx].isDismissed.toggle()
            }
        }
    }

    func toggleDismissSequel(_ item: SequelCheckSeriesItem, session: LibrarySession) {
        guard let metaDB = session.metaDB else { return }
        Task {
            if item.isDismissed {
                try? await metaDB.undismissMaintenanceItem(kind: Self.dismissalKindSequel, targetKey: item.seriesKey)
            } else {
                try? await metaDB.dismissMaintenanceItem(kind: Self.dismissalKindSequel, targetKey: item.seriesKey)
            }
            if let idx = sequelCheckItems.firstIndex(where: { $0.seriesKey == item.seriesKey }) {
                sequelCheckItems[idx].isDismissed.toggle()
            }
        }
    }
}
