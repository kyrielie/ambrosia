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
}

/// Structural sibling of `AnnotationSidebarView`: same header/empty-state/list
/// shape, same `.frame(width: 260)` sizing convention. For a `.singleBook`
/// target every `workTitle` is nil, so the section-header branch never
/// renders — behavior is identical to a flat list.
struct TOCSidebarView: View {
    let entries: [TOCPanelEntry]
    let currentSpineIndex: Int
    let onJump: (TOCPanelEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.indent")
                    .foregroundStyle(.secondary)
                Text("Contents")
                    .font(.headline)
                Spacer()
                Text("\(entries.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No table of contents found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                Spacer()
            } else {
                List {
                    ForEach(entries) { entry in
                        if entry.workTitle != nil, isFirstEntry(of: entry) {
                            Text(entry.workTitle!)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                                .padding(.top, entry.id == entries.first?.id ? 0 : 12)
                        }
                        TOCRow(entry: entry, isCurrent: entry.spineIndex == currentSpineIndex, onJump: onJump)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 260)
        .background(.background)
    }

    private func isFirstEntry(of entry: TOCPanelEntry) -> Bool {
        entries.first(where: { $0.workTitle == entry.workTitle })?.id == entry.id
    }
}

private struct TOCRow: View {
    let entry: TOCPanelEntry
    let isCurrent: Bool
    let onJump: (TOCPanelEntry) -> Void

    var body: some View {
        Text(entry.title)
            .font(.caption)
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? .primary : .secondary)
            .lineLimit(2)
            .padding(.leading, CGFloat(entry.depth) * 16)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onJump(entry) }
    }
}
