import SwiftUI

// MARK: - BookmarkSidebarView
//
// SwiftUI panel listing all bookmarks for the current book.
// Hosted in an NSPanel opened/closed by ReaderViewController.
// Jump and delete are the only actions — no editing.

struct BookmarkSidebarView: View {

    let bookmarks: [Bookmark]
    let onJump:   (Bookmark) -> Void
    let onDelete: (UUID)     -> Void

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.secondary)
                Text("Bookmarks")
                    .font(.headline)
                Spacer()
                Text("\(bookmarks.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if bookmarks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No bookmarks yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Press ⌘D while reading to add one.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                Spacer()
            } else {
                List {
                    ForEach(bookmarks.sorted { $0.characterOffset < $1.characterOffset }) { bm in
                        BookmarkRow(bookmark: bm, onJump: onJump, onDelete: onDelete)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 260)
        .background(.background)
    }
}

// MARK: - BookmarkRow

private struct BookmarkRow: View {

    let bookmark: Bookmark
    let onJump:   (Bookmark) -> Void
    let onDelete: (UUID)     -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.previewText.isEmpty ? "Bookmark" : bookmark.previewText)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.primary)

                Text(bookmark.createdDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                onDelete(bookmark.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove bookmark")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture { onJump(bookmark) }
    }
}
