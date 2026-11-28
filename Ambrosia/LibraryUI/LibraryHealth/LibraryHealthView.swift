// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Library Health Window Controller

final class LibraryHealthWindowController: NSWindowController {

    static let shared = LibraryHealthWindowController()

    private let viewModel = LibraryHealthViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library Health & File Management"
        window.minSize = NSSize(width: 740, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setFrameAutosaveName("AmbrosiaLibraryHealthWindow")
        if !window.setFrameUsingName("AmbrosiaLibraryHealthWindow") {
            window.center()
        }

        super.init(window: window)

        if let session = AppDelegate.shared?.session {
            window.contentView = NSHostingView(
                rootView: LibraryHealthView(session: session, viewModel: viewModel)
                    .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor
    static func show(tab: LibraryHealthTab? = nil) {
        if let tab {
            shared.viewModel.selectedTab = tab
        }
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Main View

struct LibraryHealthView: View {
    let session: LibrarySession
    @Bindable var viewModel: LibraryHealthViewModel

    @State private var showRemoveExactSheet = false
    @State private var includeContentMatchesInRemoval = false
    @State private var entryPendingTrash: (entry: AO3DuplicateEntry, cluster: AO3DuplicateCluster)?

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning library metadata, duplicates, WIPs, and series…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabContent
            }

            if let msg = viewModel.statusMessage {
                Divider()
                HStack {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.statusMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 740, minHeight: 500)
        .task(id: session.activePath) {
            await viewModel.loadIfNeeded(session: session)
        }
        .alert("Trash Identical Duplicates (Reversible)", isPresented: $showRemoveExactSheet) {
            Button("Move to \(viewModel.predictedTrashDestination(session: session).displayName)") {
                Task {
                    await viewModel.trashExactDuplicates(
                        includeContentMatches: includeContentMatchesInRemoval,
                        session: session
                    )
                }
            }
            Button("Copy CLI Command Instead") {
                Task {
                    let count = await viewModel.migrateExactDuplicates(
                        includeContentMatches: includeContentMatchesInRemoval,
                        session: session
                    )
                    let cmd = viewModel.prepareSafeRemovalCommand(
                        includeContentMatches: includeContentMatchesInRemoval,
                        session: session
                    )
                    copyToClipboard(cmd)
                    viewModel.statusMessage = "Migrated state for \(count) duplicate(s) and copied `calibredb remove` command."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let exactCount = viewModel.exactMatchLoserCount
            let contentCount = viewModel.contentMatchLoserCount
            let mb = String(format: "%.2f", Double(viewModel.reclaimableExactBytes) / (1024 * 1024))
            let dest = viewModel.predictedTrashDestination(session: session).displayName
            Text(
                "Found \(exactCount) byte-identical (SHA-256) redundant file(s) (\(mb) MB) " +
                "and \(contentCount) content-identical (ZIP CRC-32) file(s). " +
                "Ambrosia will migrate reading progress, annotations, and collections to each winner " +
                "and reversibly move the redundant copies to \(dest)."
            )
        }
        .alert(
            "Trash Superseded Edition (Reversible)?",
            isPresented: Binding(
                get: { entryPendingTrash != nil },
                set: { if !$0 { entryPendingTrash = nil } }
            )
        ) {
            if let pending = entryPendingTrash {
                Button("Move #\(pending.entry.calibreID) to Trash", role: .destructive) {
                    let target = pending
                    entryPendingTrash = nil
                    Task {
                        await viewModel.trashSupersededEntry(
                            entry: target.entry,
                            cluster: target.cluster,
                            session: session
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                entryPendingTrash = nil
            }
        } message: {
            if let pending = entryPendingTrash {
                let winner = pending.cluster.entries.first(where: { $0.isWinner })
                let winnerWords = winner?.wordCount.map { "\($0.formatted()) words" } ?? "unknown words"
                let loserWords = pending.entry.wordCount.map { "\($0.formatted()) words" } ?? "unknown words"
                let winnerCh = winner?.chapterCurrent.map { "Ch. \($0)" } ?? "unknown ch."
                let loserCh = pending.entry.chapterCurrent.map { "Ch. \($0)" } ?? "unknown ch."
                let dest = viewModel.predictedTrashDestination(session: session).displayName
                let annWarn = pending.entry.annotationCount > 0
                    ? "\n\nWarning: This copy has \(pending.entry.annotationCount) annotation(s). "
                        + "They will transfer to #\(pending.cluster.winnerID), "
                        + "but UTF-16 highlight offsets may not align if chapter text differs."
                    : ""
                Text(
                    "\"\(pending.cluster.title)\"\n" +
                    "Superseded #\(pending.entry.calibreID) (\(loserCh), \(loserWords)) vs. " +
                    "Winner #\(pending.cluster.winnerID) (\(winnerCh), \(winnerWords)).\n\n" +
                    "State will migrate to the winner and #\(pending.entry.calibreID) will move to \(dest).\(annWarn)"
                )
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("Section", selection: $viewModel.selectedTab) {
                ForEach(LibraryHealthTab.allCases) { tab in
                    Text(tabLabel(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            Button {
                Task { await viewModel.reload(session: session) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func tabLabel(for tab: LibraryHealthTab) -> String {
        switch tab {
        case .duplicates: return "Duplicates (\(viewModel.clusters.count))"
        case .staleWIPs: return "Stale WIPs (\(viewModel.filteredWIPs.count))"
        case .seriesGaps: return "Series Gaps (\(viewModel.gapReports.count))"
        case .seriesSequels: return "Sequels (\(viewModel.unlinkedSeriesItems.count + viewModel.filteredSequelChecks.count))"
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .duplicates: duplicatesTab
        case .staleWIPs: staleWIPsTab
        case .seriesGaps: seriesGapsTab
        case .seriesSequels: seriesSequelsTab
        }
    }

    // MARK: - Tab 1: Duplicates

    private var duplicatesTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Filter", selection: $viewModel.duplicateFilter) {
                    ForEach(DuplicateFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                TextField("Filter duplicates…", text: $viewModel.duplicateSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Spacer()

                if viewModel.isVerifyingExactDuplicates {
                    ProgressView().controlSize(.small)
                    Text("Verifying hashes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.exactMatchLoserCount > 0 {
                    Button("Safely Remove Exact (\(viewModel.exactMatchLoserCount))…") {
                        includeContentMatchesInRemoval = false
                        showRemoveExactSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            if viewModel.filteredClusters.isEmpty {
                emptyState(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "No Matching Duplicate Clusters",
                    subtitle: "Merged anthologies are excluded automatically from single-work duplicates."
                )
            } else {
                List(viewModel.filteredClusters) { cluster in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(cluster.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            if let url = URL(string: "https://archiveofourown.org/works/\(cluster.workID)") {
                                Link("AO3 #\(cluster.workID)", destination: url)
                                    .font(.caption)
                            }
                        }

                        ForEach(cluster.entries) { entry in
                            duplicateEntryRow(entry, cluster: cluster)
                        }

                        HStack(spacing: 8) {
                            let isMigrated = viewModel.migratedClusterIDs.contains(cluster.workID)
                            Button(isMigrated ? "State Migrated" : "Migrate State to Winner") {
                                viewModel.migrateCluster(cluster, session: session)
                            }
                            .disabled(isMigrated)
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Copy Calibre Remove Command") {
                                let cmd = CalibreDuplicateManager.calibrePruneCLICommand(
                                    loserIDs: cluster.loserIDs,
                                    libraryPath: session.activePath
                                )
                                copyToClipboard(cmd)
                                viewModel.statusMessage = "Copied `calibredb remove` command."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private func duplicateEntryRow(_ entry: AO3DuplicateEntry, cluster: AO3DuplicateCluster) -> some View {
        HStack(spacing: 10) {
            Text(entry.isWinner ? "Keep" : "Superseded")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.isWinner ? Color.green : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(entry.isWinner ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                .clipShape(Capsule())
                .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(entry.calibreID)").font(.caption.monospacedDigit().weight(.medium))
                    if let tier = entry.matchTier {
                        Text(tier.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(tier == .exactFileMatch ? Color.green : (tier == .contentMatch ? Color.blue : Color.orange))
                    }
                    if let words = entry.wordCount {
                        Text("· \(words.formatted()) words").font(.caption).foregroundStyle(.secondary)
                    }
                    if let curr = entry.chapterCurrent {
                        let tot = entry.chapterTotal.map(String.init) ?? "?"
                        Text("· Ch. \(curr)/\(tot)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let upd = entry.updatedDate, !upd.isEmpty {
                        Text("Updated: \(upd)").font(.caption2).foregroundStyle(.secondary)
                    } else if let pub = entry.publishedDate, !pub.isEmpty {
                        Text("Published: \(pub)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let added = entry.dateAdded {
                        Text("· Added: \(Self.dateFormatter.string(from: added))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if entry.readPercent > 0 {
                        Text("· \(Int(entry.readPercent * 100))% read").font(.caption2)
                    }
                    if entry.annotationCount > 0 {
                        Text("· \(entry.annotationCount) notes").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if !entry.isWinner {
                Button("Set Winner") {
                    viewModel.setWinner(clusterID: cluster.workID, newWinnerID: entry.calibreID, session: session)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("Trash…") {
                    entryPendingTrash = (entry: entry, cluster: cluster)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(viewModel.isTrashing)
            }

            Button { openInReader(calibreID: entry.calibreID) } label: { Image(systemName: "book") }
                .buttonStyle(.borderless)
                .help("Open in Reader")

            Button { revealInFinder(calibreID: entry.calibreID) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(entry.isWinner ? Color.green.opacity(0.06) : Color.clear)
        .cornerRadius(6)
    }

    // MARK: - Tab 2: Stale WIPs

    private var staleWIPsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Age", selection: $viewModel.wipAgeFilter) {
                    ForEach(WIPAgeFilter.allCases) { age in
                        Text(age.rawValue).tag(age)
                    }
                }
                .frame(width: 135)

                Picker("By", selection: $viewModel.wipDateBasis) {
                    ForEach(WIPDateBasis.allCases) { basis in
                        Text(basis.rawValue).tag(basis)
                    }
                }
                .frame(width: 125)

                Toggle("Started / Read Later", isOn: $viewModel.wipOnlyStartedOrReadLater)
                    .toggleStyle(.checkbox)

                Toggle("Hide Skipped", isOn: $viewModel.wipHideSkipped)
                    .toggleStyle(.checkbox)

                Toggle("Dismissed", isOn: $viewModel.wipShowDismissed)
                    .toggleStyle(.checkbox)

                Spacer()

                TextField("Filter WIPs…", text: $viewModel.wipSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)

                Button("Export Update List…") {
                    exportWIPUpdateManifest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.filteredWIPs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            if viewModel.filteredWIPs.isEmpty {
                emptyState(
                    icon: "clock",
                    color: .secondary,
                    title: "No Matching WIPs",
                    subtitle: "Try adjusting the age threshold or date basis."
                )
            } else {
                List(viewModel.filteredWIPs) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                if !item.authors.isEmpty {
                                    Text(item.authors.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let cc = item.chapterCurrent {
                                    let ct = item.chapterTotal.map(String.init) ?? "?"
                                    Text("· Ch. \(cc)/\(ct)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let wc = item.wordCount {
                                    Text("· \(wc.formatted()) words")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                if let upd = item.updatedDate ?? item.publishedDate {
                                    Text("AO3 Updated: \(Self.dateFormatter.string(from: upd))")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                if let added = item.dateAdded {
                                    Text("· Added: \(Self.dateFormatter.string(from: added))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()

                        if let wid = item.workID, let url = URL(string: "https://archiveofourown.org/works/\(wid)") {
                            Link("AO3", destination: url)
                                .font(.caption)
                        }

                        Button { openInReader(calibreID: item.calibreID) } label: { Image(systemName: "book") }
                            .buttonStyle(.borderless)
                            .help("Open in Reader")

                        Button(item.isDismissed ? "Restore" : "Dismiss") {
                            viewModel.toggleDismissWIP(item, session: session)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Tab 3: Series Gaps

    private var seriesGapsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Gap Type", selection: $viewModel.gapFilter) {
                    ForEach(SeriesGapFilter.allCases) { gapFilterOption in
                        Text(gapFilterOption.rawValue).tag(gapFilterOption)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                TextField("Filter series…", text: $viewModel.gapSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            if viewModel.filteredGapReports.isEmpty {
                emptyState(
                    icon: "list.number",
                    color: .secondary,
                    title: "No Missing Series Parts",
                    subtitle: "All tracked series have contiguous part numbers from Part 1."
                )
            } else {
                List(viewModel.filteredGapReports, id: \.seriesKey) { report in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.items, id: \.partIndex) { (item: SeriesGapItem) in
                                HStack {
                                    Text("Part \(item.partIndex)")
                                        .font(.caption.monospacedDigit().weight(.medium))
                                        .frame(width: 54, alignment: .leading)
                                    Text(item.title)
                                        .font(.caption)
                                        .foregroundStyle(item.isPresent ? Color.primary : Color.orange)
                                    Spacer()
                                    if let url = item.url {
                                        Link(item.isPresent ? "AO3" : "Find on AO3", destination: url)
                                            .font(.caption2)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.seriesName).font(.subheadline.weight(.semibold))
                                let missingStr = report.missingIndices.map(String.init).joined(separator: ", ")
                                Text("\(report.presentIndices.count) of \(report.totalKnownParts) parts · Missing: \(missingStr)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Export Manifest…") {
                                exportSeriesGapManifest(report)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Tab 4: Series Sequels

    private var seriesSequelsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Unlinked Local (\(viewModel.filteredUnlinkedSeries.count)) · Sequel Queue (\(viewModel.filteredSequelChecks.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Show Dismissed", isOn: $viewModel.sequelShowDismissed)
                    .toggleStyle(.checkbox)
                TextField("Filter series or works…", text: $viewModel.sequelSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            List {
                if !viewModel.filteredUnlinkedSeries.isEmpty {
                    Section("Unlinked Local Works (AO3 Series in Metadata, Missing in Calibre)") {
                        ForEach(viewModel.filteredUnlinkedSeries) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.medium))
                                    let seriesDesc = item.seriesEntries.map { "\($0.name) #\($0.index)" }.joined(separator: ", ")
                                    Text("AO3 Series: \(seriesDesc)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { openInReader(calibreID: item.calibreID) } label: { Image(systemName: "book") }
                                    .buttonStyle(.borderless)
                                Button { revealInFinder(calibreID: item.calibreID) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if !viewModel.filteredSequelChecks.isEmpty {
                    Section("Completed / Finished Series (Check AO3 for Sequels)") {
                        ForEach(viewModel.filteredSequelChecks, id: \.seriesKey) { (item: SequelCheckSeriesItem) in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.seriesName).font(.subheadline.weight(.medium))
                                    Text("\(item.presentCount) local part(s) · Latest: \(item.latestTitle)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let url = URL(string: "https://archiveofourown.org/series/\(item.ao3SeriesID)") {
                                    Link("Check AO3", destination: url)
                                        .font(.caption)
                                }
                                Button(item.isDismissed ? "Restore" : "Dismiss") {
                                    viewModel.toggleDismissSequel(item, session: session)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: - Helpers

    private func emptyState(icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(color)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func exportWIPUpdateManifest() {
        let urls = viewModel.filteredWIPs.compactMap { item -> String? in
            item.workID.map { "https://archiveofourown.org/works/\($0)" }
        }
        guard !urls.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "stale_wips_update_check.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let header = "# Stale WIPs Update Manifest (\(urls.count) works)\n# Run with: ao3downloader -f stale_wips_update_check.txt\n\n"
            try? (header + urls.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportSeriesGapManifest(_ report: SeriesGapReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .html]
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let safeName = report.seriesName.components(separatedBy: invalid).joined(separator: "_")
        panel.nameFieldStringValue = "\(safeName)_manifest.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = url.pathExtension.lowercased() == "html"
                ? SeriesGapManifestBuilder.generateHTMLManifest(report: report)
                : SeriesGapManifestBuilder.generateTextManifest(report: report)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
