// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

enum ImportSheetFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case conflicts = "Conflicts"
    case updates = "Updates"
    case newWorks = "New"
    case skipped = "Skipped"

    var id: String { rawValue }
}

@Observable
@MainActor
final class EPUBImportSheetViewModel {
    var isScanning = true
    var scanProgressCurrent = 0
    var scanProgressTotal = 0
    var scanCurrentTitle = ""

    var items: [EPUBImportTriageItem] = []
    var scanErrors: [String] = []
    var filter: ImportSheetFilter = .all

    var isCommitting = false
    var commitProgressCurrent = 0
    var commitProgressTotal = 0
    var commitCurrentTitle = ""
    var commitResult: CalibreImportResult?
    var commitError: String?

    var collapsedCategories: Set<ImportTriageCategory> = []

    func runTriage(urls: [URL], session: LibrarySession) async {
        isScanning = true
        let epubURLs = EPUBImportTriageEngine.collectEPUBURLs(from: urls)
        scanProgressTotal = epubURLs.count
        let (triaged, errors) = await EPUBImportTriageEngine.inspectAndTriage(
            epubURLs: epubURLs,
            session: session
        ) { current, total, title in
            Task { @MainActor [weak self] in
                self?.scanProgressCurrent = current
                self?.scanProgressTotal = total
                self?.scanCurrentTitle = title
            }
        }
        items = triaged
        scanErrors = errors
        let skippedCount = triaged.filter { $0.category == .exactDuplicate || $0.category == .olderRevision }.count
        if skippedCount > 5 {
            collapsedCategories.insert(.exactDuplicate)
            collapsedCategories.insert(.olderRevision)
        }
        isScanning = false
    }

    var summaryHeadline: String {
        let updates = items.filter { $0.selectedAction == .updateExisting || $0.selectedAction == .replaceExisting }.count
        let added = items.filter { $0.selectedAction == .importNew || $0.selectedAction == .keepBoth }.count
        let conflicts = items.filter { $0.category == .conflict }.count
        let skipped = items.filter { !$0.selectedAction.isMutating }.count
        return "Import \(items.count) EPUB\(items.count == 1 ? "" : "s") — \(updates) Updates · \(added) New · \(conflicts) Conflicts · \(skipped) Skipped"
    }

    var pendingMutationCount: Int {
        items.filter { $0.selectedAction.isMutating }.count
    }

    var annotatedOverwriteCount: Int {
        items.filter {
            ($0.selectedAction == .updateExisting || $0.selectedAction == .replaceExisting)
                && ($0.matchedBook?.annotationCount ?? 0) > 0
        }.count
    }

    func switchAnnotatedConflictsToKeepBoth() {
        for idx in items.indices {
            let isOverwrite = items[idx].selectedAction == .updateExisting || items[idx].selectedAction == .replaceExisting
            if isOverwrite && (items[idx].matchedBook?.annotationCount ?? 0) > 0
                && items[idx].availableActions.contains(.keepBoth) {
                items[idx].selectedAction = .keepBoth
            }
        }
    }

    func items(for category: ImportTriageCategory) -> [EPUBImportTriageItem] {
        items.filter { item in
            guard item.category == category else { return false }
            switch filter {
            case .all: return true
            case .conflicts: return item.category == .conflict
            case .updates: return item.category == .newerRevision
            case .newWorks: return item.category == .newBook || item.category == .anthology
            case .skipped: return !item.selectedAction.isMutating
            }
        }
    }

    func setAction(_ action: ImportResolutionAction, for itemID: UUID) {
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].selectedAction = action
        }
    }

    func applyCategoryAction(_ action: ImportResolutionAction, category: ImportTriageCategory) {
        for idx in items.indices where items[idx].category == category {
            if items[idx].availableActions.contains(action) {
                items[idx].selectedAction = action
            }
        }
    }

    func applyRecommendedAll() {
        for idx in items.indices {
            items[idx].selectedAction = items[idx].recommendedAction
        }
    }

    func skipAll() {
        for idx in items.indices {
            items[idx].selectedAction = .skip
        }
    }

    func commit(session: LibrarySession) async {
        guard !isCommitting else { return }
        isCommitting = true
        commitError = nil
        do {
            let result = try await CalibreImportManager.commitImport(
                items: items,
                session: session
            ) { current, total, title in
                Task { @MainActor [weak self] in
                    self?.commitProgressCurrent = current
                    self?.commitProgressTotal = total
                    self?.commitCurrentTitle = title
                }
            }
            commitResult = result
        } catch {
            commitError = error.localizedDescription
        }
        isCommitting = false
    }
}

struct EPUBImportConfirmationSheet: View {
    let urls: [URL]
    let session: LibrarySession
    let onDismiss: () -> Void

    @State private var viewModel = EPUBImportSheetViewModel()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if viewModel.isScanning {
                scanningView
            } else if let result = viewModel.commitResult {
                resultSummaryView(result)
            } else if viewModel.items.isEmpty {
                emptyView
            } else {
                triageListView
            }

            Divider()
            if viewModel.annotatedOverwriteCount > 0 && viewModel.commitResult == nil && !viewModel.isScanning {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(viewModel.annotatedOverwriteCount) book(s) have highlights or bookmarks that will auto-reanchor on next open.")
                        .font(.caption)
                    Spacer()
                    Button("Switch Annotated to Keep Both") {
                        viewModel.switchAnnotatedConflictsToKeepBoth()
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                Divider()
            }
            footerView
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await viewModel.runTriage(urls: urls, session: session)
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Import & Pre-Triage EPUBs")
                    .font(.headline)
                Spacer()
                if !viewModel.isScanning && viewModel.commitResult == nil {
                    Text(viewModel.summaryHeadline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.isScanning && viewModel.commitResult == nil && !viewModel.items.isEmpty {
                Picker("Filter", selection: $viewModel.filter) {
                    ForEach(ImportSheetFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var scanningView: some View {
        VStack(spacing: 12) {
            ProgressView(
                value: Double(viewModel.scanProgressCurrent),
                total: Double(max(viewModel.scanProgressTotal, 1))
            )
            .frame(maxWidth: 340)
            Text("Inspecting \(viewModel.scanProgressCurrent) of \(viewModel.scanProgressTotal): \(viewModel.scanCurrentTitle)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No valid EPUB files found")
                .font(.headline)
            if !viewModel.scanErrors.isEmpty {
                Text(viewModel.scanErrors.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var triageListView: some View {
        List {
            ForEach(ImportTriageCategory.allCases) { category in
                let catItems = viewModel.items(for: category)
                if !catItems.isEmpty {
                    Section {
                        if !viewModel.collapsedCategories.contains(category) {
                            ForEach(catItems) { item in
                                triageRow(item)
                            }
                        }
                    } header: {
                        sectionHeader(category: category, count: catItems.count)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func sectionHeader(category: ImportTriageCategory, count: Int) -> some View {
        HStack {
            Button {
                if viewModel.collapsedCategories.contains(category) {
                    viewModel.collapsedCategories.remove(category)
                } else {
                    viewModel.collapsedCategories.insert(category)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.collapsedCategories.contains(category) ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                    Text("\(category.rawValue) (\(count))")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if category == .newerRevision {
                Button("Update All") { viewModel.applyCategoryAction(.updateExisting, category: category) }
                    .font(.caption).buttonStyle(.borderless)
            } else if category == .newBook || category == .anthology {
                Button("Import All") { viewModel.applyCategoryAction(.importNew, category: category) }
                    .font(.caption).buttonStyle(.borderless)
            }
            Button("Skip All") { viewModel.applyCategoryAction(.skip, category: category) }
                .font(.caption).buttonStyle(.borderless)
        }
    }

    private func triageRow(_ item: EPUBImportTriageItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.incoming.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let wid = item.incoming.ao3WorkID {
                        Text("AO3 #\(wid)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(item.incoming.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(item.matchReason)
                    .font(.caption2)
                    .foregroundStyle(item.category == .conflict ? .orange : .secondary)

                if let matched = item.matchedBook {
                    HStack(spacing: 8) {
                        Text("Library: \(formatStats(ch: matched.chapterCurrent, total: matched.chapterTotal, words: matched.wordCount))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("→ Incoming: \(formatStats(ch: item.incoming.chapterCurrent, total: item.incoming.chapterTotal, words: item.incoming.wordCount))")
                            .font(.caption2)
                    }

                    HStack(spacing: 6) {
                        if matched.annotationCount > 0
                            && (item.selectedAction == .updateExisting || item.selectedAction == .replaceExisting) {
                            Text("\(matched.annotationCount) annotation(s) will auto-reanchor")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if matched.isOpenInReader {
                            Text("Open in Reader")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        if let existingURL = matched.epubURL {
                            Button("Open Library Copy") {
                                NSWorkspace.shared.open(existingURL)
                            }
                            .font(.caption2).buttonStyle(.borderless)
                        }
                        Button("Preview Incoming") {
                            NSWorkspace.shared.open(item.incoming.url)
                        }
                        .font(.caption2).buttonStyle(.borderless)
                    }
                }
            }

            Spacer()

            Picker("Action", selection: Binding(
                get: { item.selectedAction },
                set: { viewModel.setAction($0, for: item.id) }
            )) {
                ForEach(item.availableActions) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.vertical, 4)
    }

    private func resultSummaryView(_ result: CalibreImportResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(result.errors.isEmpty ? .green : .orange)
            Text("Updated \(result.updatedIDs.count) work(s) · Added \(result.addedIDs.count) new · Skipped \(result.skippedCount)")
                .font(.headline)
            if !result.errors.isEmpty {
                ScrollView {
                    Text(result.errors.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            if let err = viewModel.commitError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if viewModel.isCommitting {
                ProgressView(
                    value: Double(viewModel.commitProgressCurrent),
                    total: Double(max(viewModel.commitProgressTotal, 1))
                )
                .frame(width: 160)
                Text("Importing \(viewModel.commitProgressCurrent)/\(viewModel.commitProgressTotal)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.commitResult == nil && !viewModel.items.isEmpty {
                Menu("Quick Actions") {
                    Button("Apply Recommended") { viewModel.applyRecommendedAll() }
                    Button("Skip All") { viewModel.skipAll() }
                }
                .frame(width: 130)
            }

            Spacer()

            if viewModel.commitResult != nil {
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isCommitting)

                Button("Apply (\(viewModel.pendingMutationCount))") {
                    Task { await viewModel.commit(session: session) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isScanning || viewModel.isCommitting || viewModel.pendingMutationCount == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func formatStats(ch: Int?, total: Int?, words: Int?) -> String {
        let chStr = ch.map { "Ch. \($0)/\(total.map(String.init) ?? "?")" } ?? "Ch. ?"
        let wStr = words.map { "\($0.formatted()) words" } ?? "? words"
        return "\(chStr) · \(wStr)"
    }
}
