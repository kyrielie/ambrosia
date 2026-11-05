import SwiftUI

enum EmailReaderSidebarMode: String, CaseIterable, Identifiable {
    case annotations
    case tableOfContents
    case info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .annotations: return "Annotations"
        case .tableOfContents: return "Contents"
        case .info: return "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .annotations: return "text.badge.checkmark"
        case .tableOfContents: return "list.bullet.indent"
        case .info: return "info.circle"
        }
    }
}

struct EmailReaderSidebarView: View {
    let mode: EmailReaderSidebarMode
    let annotations: [Annotation]
    let onJumpToAnnotation: (Annotation) -> Void
    let onDeleteAnnotation: (UUID) -> Void
    let tocEntries: [TOCPanelEntry]
    let currentSpineIndex: Int
    let onJumpToTOCEntry: (TOCPanelEntry) -> Void
    var selectedBook: CalibreBook?
    var bookState: BookState?
    var libraryRoot: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: mode.systemImage)
                    .foregroundStyle(.secondary)
                Text(mode.title)
                    .font(.headline)
                Spacer()
            }
            .padding(12)

            Divider()

            switch mode {
            case .annotations:
                AnnotationSidebarView(annotations: annotations, onJump: onJumpToAnnotation, onDelete: onDeleteAnnotation)
            case .tableOfContents:
                TOCSidebarView(entries: tocEntries, currentSpineIndex: currentSpineIndex, onJump: onJumpToTOCEntry)
            case .info:
                EmailDetailView(book: selectedBook, bookState: bookState, libraryRoot: libraryRoot)
            }
        }
        .frame(minWidth: 260, idealWidth: 300)
        .background(.background)
    }
}
