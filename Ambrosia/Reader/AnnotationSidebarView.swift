import SwiftUI

// MARK: - AnnotationSidebarView
//
// Replaces BookmarkSidebarView. Lists all Annotations for the current book.
// Hosted in an NSPanel opened/closed by ReaderViewController (⌘B).
//
// Both point annotations (old bookmarks: startChar == endChar) and ranged
// annotations (highlights) are shown sorted by (spineIndex, startChar).

struct AnnotationSidebarView: View {

    let annotations: [Annotation]
    let onJump: (Annotation) -> Void
    let onDelete: (UUID) -> Void

    @State private var filterQuery = ""

    private var sorted: [Annotation] {
        let base = annotations.sorted {
            if $0.spineIndex != $1.spineIndex { return $0.spineIndex < $1.spineIndex }
            return $0.startChar < $1.startChar
        }
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return base }
        return base.filter {
            $0.selectedText.lowercased().contains(trimmed)
                || ($0.note?.lowercased().contains(trimmed) ?? false)
        }
    }

    private var bookmarkShortcutHint: String {
        ReaderPreferences.shared.keyBindings[.addAnnotation]?.displayString ?? "⌘D"
    }

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.secondary)
                Text("Annotations")
                    .font(.headline)
                Spacer()
                Text("\(sorted.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !annotations.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    TextField("Filter annotations…", text: $filterQuery)
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
            }

            Divider()

            if sorted.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(filterQuery.isEmpty ? "No annotations yet" : "No matching annotations")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if filterQuery.isEmpty {
                        Text("Press \(bookmarkShortcutHint) to bookmark.\nSelect text and right-click to highlight.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                Spacer()
            } else {
                List {
                    ForEach(sorted) { annotation in
                        AnnotationRow(
                            annotation: annotation,
                            onJump: onJump,
                            onDelete: onDelete
                        )
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

// MARK: - AnnotationRow

private struct AnnotationRow: View {

    let annotation: Annotation
    let onJump: (Annotation) -> Void
    let onDelete: (UUID) -> Void

    @State private var isEditingNote: Bool = false

    private var symbolName: String {
        annotation.isPointAnnotation ? "bookmark.fill" : "highlighter"
    }

    private var accentColor: Color {
        ReaderPreferences.shared.highlightPalette.swiftUIColor(
            for: annotation.colorKey,
            isDark: ReaderPreferences.shared.effectiveIsDark
        )
    }

    private var previewText: String {
        if annotation.isPointAnnotation {
            return annotation.note ?? "Bookmark"
        }
        let text = annotation.selectedText
        return text.isEmpty ? "Highlight" : String(text.prefix(60))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onJump(annotation)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbolName)
                        .foregroundStyle(accentColor)
                        .font(.caption)
                        .padding(.top, 3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(previewText)
                            .font(.caption)
                            .lineLimit(3)
                            .foregroundStyle(.primary)

                        if let note = annotation.note, !note.isEmpty, !isEditingNote {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .italic()
                        }

                        Text(annotation.createdDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onDelete(annotation.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove annotation")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
