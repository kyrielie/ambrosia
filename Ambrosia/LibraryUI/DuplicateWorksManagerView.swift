import AppKit
import SwiftUI

/// Sheet UI for reviewing and managing duplicate Calibre rows for AO3 works.
///
/// Gives users complete transparency into version diffs (word counts, chapters,
/// revision dates, reading progress) and safely migrates user state to the
/// canonical winner before providing safe Calibre CLI cleanup commands.
struct DuplicateWorksManagerView: View {
    let session: LibrarySession
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var clusters: [AO3DuplicateCluster] = []
    @State private var isLoading = true
    @State private var statusMessage: String?
    @State private var filterText = ""
    @State private var migratedClusterIDs: Set<String> = []

    init(session: LibrarySession, onDismiss: (() -> Void)? = nil) {
        self.session = session
        self.onDismiss = onDismiss
    }

    private func doDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning library for duplicate AO3 works…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if clusters.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("No Duplicate AO3 Works Detected")
                        .font(.headline)
                    Text("All AO3 works in your Calibre library have unique work IDs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                duplicateClustersList
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 480, idealHeight: 600)
        .preventInitialButtonFocus()
        .onExitCommand { doDismiss() }
        .task {
            await loadDuplicates()
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate AO3 Works Manager")
                    .font(.headline)
                if !clusters.isEmpty {
                    Text("\(clusters.count) duplicate cluster\(clusters.count == 1 ? "" : "s") found (\(totalRedundantCount) redundant Calibre rows)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !clusters.isEmpty {
                TextField("Filter duplicates…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            Button("Done") {
                doDismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var duplicateClustersList: some View {
        List {
            ForEach(filteredClusters) { cluster in
                clusterSection(cluster)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func clusterSection(_ cluster: AO3DuplicateCluster) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                clusterHeader(cluster)
                ForEach(cluster.entries) { entry in
                    entryRow(entry, cluster: cluster)
                }
                clusterActionRow(cluster)
            }
            .padding(.vertical, 6)
        }
    }

    private func clusterHeader(_ cluster: AO3DuplicateCluster) -> some View {
        HStack {
            Text(cluster.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer()
            Link(destination: URL(string: "https://archiveofourown.org/works/\(cluster.workID)") ?? URL(fileURLWithPath: "/")) {
                HStack(spacing: 4) {
                    Text("AO3 #\(cluster.workID)")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.caption)
            }
        }
    }

    private func entryRow(_ entry: AO3DuplicateEntry, cluster: AO3DuplicateCluster) -> some View {
        HStack(alignment: .center, spacing: 12) {
            statusBadge(isWinner: entry.isWinner)
                .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Calibre ID: \(entry.calibreID)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                    if let words = entry.wordCount {
                        Text("• \(formatNumber(words)) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let curr = entry.chapterCurrent {
                        let total = entry.chapterTotal.map { "\($0)" } ?? "?"
                        Text("• Ch. \(curr)/\(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    if let upd = entry.updatedDate, !upd.isEmpty {
                        Text("Updated: \(upd)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let pub = entry.publishedDate, !pub.isEmpty {
                        Text("Published: \(pub)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if entry.readPercent > 0 {
                        Text("• \(Int(entry.readPercent * 100))% read")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                    if entry.annotationCount > 0 {
                        Text("• \(entry.annotationCount) annotation\(entry.annotationCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if !entry.isWinner {
                    Button("Set as Winner") {
                        setWinner(clusterID: cluster.workID, newWinnerID: entry.calibreID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Designates this Calibre entry as the winner to keep.")
                }

                Button {
                    openInReader(calibreID: entry.calibreID)
                } label: {
                    Image(systemName: "book")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open this edition in Reader")

                Button {
                    revealInFinder(calibreID: entry.calibreID)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reveal this EPUB file in Finder")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(entry.isWinner ? Color.green.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }

    private func statusBadge(isWinner: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isWinner ? "checkmark.circle.fill" : "arrow.triangle.merge")
            Text(isWinner ? "Keep" : "Superseded")
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(isWinner ? Color.green : Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isWinner ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }

    private func clusterActionRow(_ cluster: AO3DuplicateCluster) -> some View {
        HStack(spacing: 10) {
            let isMigrated = migratedClusterIDs.contains(cluster.workID)

            Button {
                migrateCluster(cluster)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isMigrated ? "checkmark" : "arrow.right.arrow.left")
                    Text(isMigrated ? "State Migrated" : "Migrate State to Winner")
                }
            }
            .disabled(isMigrated)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Copy Calibre Search") {
                copyCalibreSearch(for: cluster)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Copy Calibre Remove Command") {
                copyCalibrePrune(for: cluster)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Filter in Library") {
                filterInLibrary(cluster: cluster)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Filter main library to view duplicate entries together.")

            Spacer()
        }
        .padding(.top, 4)
    }

    private var footerBar: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !clusters.isEmpty {
                Button("Copy All Calibre Prune Commands") {
                    copyAllCalibrePrune()
                }
                .buttonStyle(.bordered)

                Button("Migrate All States") {
                    migrateAllClusters()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Logic & Actions

    private var totalRedundantCount: Int {
        clusters.reduce(0) { $0 + $1.loserIDs.count }
    }

    private var filteredClusters: [AO3DuplicateCluster] {
        if filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            return clusters
        }
        let term = filterText.lowercased()
        return clusters.filter { cluster in
            cluster.title.lowercased().contains(term)
                || cluster.workID.contains(term)
                || cluster.entries.contains { $0.title.lowercased().contains(term) || "\($0.calibreID)".contains(term) }
        }
    }

    private func loadDuplicates() async {
        isLoading = true
        guard let metaDB = session.metaDB, let library = session.library else {
            isLoading = false
            return
        }

        let workIDs = await metaDB.allAO3WorkIDs()
        let dates = await metaDB.allAO3Dates()
        let loserIDs = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)

        guard !loserIDs.isEmpty else {
            clusters = []
            isLoading = false
            return
        }

        // Collect all IDs in duplicate groups
        let grouped = Dictionary(grouping: workIDs.keys, by: { workIDs[$0] ?? "" })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
        let allDupIDs = Array(Set(grouped.values.flatMap { $0 }))

        let books: [CalibreBook] = await library.booksForIDs(allDupIDs)
        let booksByID: [Int: CalibreBook] = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let metaByID = (try? await metaDB.ao3Metadata(for: allDupIDs)) ?? [:]
        let statesByID = await metaDB.bookStates(for: allDupIDs)

        var annotationsByID: [Int: Int] = [:]
        for id in allDupIDs {
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
            annotationCountsByID: annotationsByID
        )

        isLoading = false
    }

    private func migrateCluster(_ cluster: AO3DuplicateCluster) {
        guard let metaDB = session.metaDB else { return }
        Task {
            do {
                for loserID in cluster.loserIDs {
                    try await metaDB.transferBookState(fromLoserID: loserID, toWinnerID: cluster.winnerID)
                }
                migratedClusterIDs.insert(cluster.workID)
                statusMessage = "Migrated state for \"\(cluster.title)\""
            } catch {
                statusMessage = "Migration failed: \(error.localizedDescription)"
            }
        }
    }

    private func migrateAllClusters() {
        guard let metaDB = session.metaDB else { return }
        Task {
            var count = 0
            for cluster in clusters {
                for loserID in cluster.loserIDs {
                    try? await metaDB.transferBookState(fromLoserID: loserID, toWinnerID: cluster.winnerID)
                }
                migratedClusterIDs.insert(cluster.workID)
                count += 1
            }
            statusMessage = "Successfully migrated state across \(count) duplicate clusters."
        }
    }

    private func copyCalibreSearch(for cluster: AO3DuplicateCluster) {
        let query = CalibreDuplicateManager.calibreSearchQuery(calibreIDs: cluster.entries.map(\.calibreID))
        copyToClipboard(query)
        statusMessage = "Copied Calibre search query to clipboard: \(query)"
    }

    private func copyCalibrePrune(for cluster: AO3DuplicateCluster) {
        let libPath = session.activePath
        let command = CalibreDuplicateManager.calibrePruneCLICommand(
            loserIDs: cluster.loserIDs,
            libraryPath: libPath
        )
        copyToClipboard(command)
        statusMessage = "Copied Calibre remove command to clipboard."
    }

    private func copyAllCalibrePrune() {
        let allLoserIDs = Array(Set(clusters.flatMap(\.loserIDs)))
        let libPath = session.activePath
        let command = CalibreDuplicateManager.calibrePruneCLICommand(
            loserIDs: allLoserIDs,
            libraryPath: libPath
        )
        copyToClipboard(command)
        statusMessage = "Copied Calibre remove command for all \(allLoserIDs.count) redundant works."
    }

    private func setWinner(clusterID: String, newWinnerID: Int) {
        guard let idx = clusters.firstIndex(where: { $0.workID == clusterID }) else { return }
        let updated = clusters[idx].withWinner(newWinnerID)
        clusters[idx] = updated
        statusMessage = "Set Calibre ID #\(newWinnerID) as preferred winner for \"\(updated.title)\""
    }

    private func openInReader(calibreID: Int) {
        guard let library = session.library else { return }
        Task { @MainActor in
            let books = await library.booksForIDs([calibreID])
            if let book = books.first {
                AppDelegate.shared?.openReaderWindow(book: book)
            }
        }
    }

    private func revealInFinder(calibreID: Int) {
        guard let library = session.library else { return }
        Task { @MainActor in
            let books = await library.booksForIDs([calibreID])
            if let book = books.first {
                AppDelegate.shared?.revealInFinder(book: book)
            }
        }
    }

    private func filterInLibrary(cluster: AO3DuplicateCluster) {
        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.searchText = cluster.title
        dismiss()
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}
