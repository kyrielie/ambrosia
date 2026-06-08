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
    let onJump:   (Annotation) -> Void
    let onDelete: (UUID)       -> Void

    private var sorted: [Annotation] {
        annotations.sorted {
            if $0.spineIndex != $1.spineIndex { return $0.spineIndex < $1.spineIndex }
            return $0.startChar < $1.startChar
        }
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
                Text("\(annotations.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if annotations.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No annotations yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Press ⌘D to bookmark.\nSelect text and right-click to highlight.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
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
    let onJump:   (Annotation) -> Void
    let onDelete: (UUID)       -> Void

    @State private var isEditingNote: Bool = false

    private var symbolName: String {
        annotation.isPointAnnotation ? "bookmark.fill" : "highlighter"
    }

    private var accentColor: Color {
        Color(hex: annotation.colorHex) ?? .yellow
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

            Spacer()

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
        .contentShape(Rectangle())
        .onTapGesture { onJump(annotation) }
    }
}

// MARK: - Color hex helper

private extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
