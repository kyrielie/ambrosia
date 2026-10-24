import SwiftUI

/// UI-facing table-of-contents entry, distinct from `EPUBParser.TOCEntry`
/// (which stays parser-local). `spineIndex` here is always global — already
/// resolved through `SeriesSpineMap` (see ReaderViewController.globalTOC).
struct TOCPanelEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let spineIndex: Int      // global
    let depth: Int
    let workTitle: String?   // nil for singleBook; section header for series
    let fragment: String?

    init(id: String, title: String, spineIndex: Int, depth: Int, workTitle: String? = nil, fragment: String? = nil) {
        self.id = id
        self.title = title
        self.spineIndex = spineIndex
        self.depth = depth
        self.workTitle = workTitle
        self.fragment = fragment
    }
}

/// A group of TOC entries belonging to one work in a series.
private struct TOCWorkGroup: Identifiable {
    let id: String
    let title: String
    let entries: [TOCPanelEntry]
}

/// Floating utility window / sidebar view for Table of Contents, matching AnnotationSidebarView
/// conventions and featuring per-work dropdowns for grouped series and live search filtering.
struct TOCSidebarView: View {
    let entries: [TOCPanelEntry]
    let currentSpineIndex: Int
    let onJump: (TOCPanelEntry) -> Void

    @State private var filterQuery = ""
    @State private var expandedWorkIDs: Set<String> = []

    private var filteredEntries: [TOCPanelEntry] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.title.lowercased().contains(trimmed) }
    }

    private var isGroupedSeries: Bool {
        entries.contains { $0.workTitle != nil }
    }

    private var workGroups: [TOCWorkGroup] {
        var groups: [TOCWorkGroup] = []
        var currentTitle: String?
        var currentEntries: [TOCPanelEntry] = []

        for entry in filteredEntries {
            let title = entry.workTitle ?? "Work"
            if currentTitle == nil {
                currentTitle = title
            }
            if title == currentTitle {
                currentEntries.append(entry)
            } else {
                if let currentTitle, !currentEntries.isEmpty {
                    groups.append(TOCWorkGroup(id: currentTitle, title: currentTitle, entries: currentEntries))
                }
                currentTitle = title
                currentEntries = [entry]
            }
        }
        if let currentTitle, !currentEntries.isEmpty {
            groups.append(TOCWorkGroup(id: currentTitle, title: currentTitle, entries: currentEntries))
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.indent")
                    .foregroundStyle(.secondary)
                Text("Contents")
                    .font(.headline)
                Spacer()
                Text("\(filteredEntries.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Search filter field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Filter chapters…", text: $filterQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !filterQuery.isEmpty {
                    Button {
                        filterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()

            if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(filterQuery.isEmpty ? "No table of contents found" : "No matching chapters")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if isGroupedSeries {
                            ForEach(workGroups) { group in
                                let isExpanded = Binding<Bool>(
                                    get: { expandedWorkIDs.contains(group.id) },
                                    set: { expand in
                                        if expand {
                                            expandedWorkIDs.insert(group.id)
                                        } else {
                                            expandedWorkIDs.remove(group.id)
                                        }
                                    }
                                )
                                DisclosureGroup(isExpanded: isExpanded) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        ForEach(group.entries) { entry in
                                            TOCRow(
                                                entry: entry,
                                                isCurrent: entry.spineIndex == currentSpineIndex,
                                                onJump: onJump
                                            )
                                        }
                                    }
                                    .padding(.leading, 6)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "book.closed")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                        Text(group.title)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(group.entries.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                            }
                        } else {
                            ForEach(filteredEntries) { entry in
                                TOCRow(
                                    entry: entry,
                                    isCurrent: entry.spineIndex == currentSpineIndex,
                                    onJump: onJump
                                )
                                .padding(.horizontal, 10)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(minWidth: 260, idealWidth: 280, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            initializeExpandedWorks()
        }
        .onChange(of: entries) { _, _ in
            initializeExpandedWorks()
        }
    }

    private func initializeExpandedWorks() {
        if isGroupedSeries {
            // Expand all works by default
            let allIDs = Set(entries.compactMap(\.workTitle))
            if !allIDs.isEmpty {
                expandedWorkIDs = allIDs
            }
        }
    }
}

private struct TOCRow: View {
    let entry: TOCPanelEntry
    let isCurrent: Bool
    let onJump: (TOCPanelEntry) -> Void

    var body: some View {
        Button {
            onJump(entry)
        } label: {
            HStack(spacing: 6) {
                if isCurrent {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                } else {
                    Spacer().frame(width: 5)
                }

                Text(entry.title)
                    .font(.caption)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(min(entry.depth, 4)) * 12)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
