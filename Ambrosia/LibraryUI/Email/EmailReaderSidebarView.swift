import SwiftUI

enum EmailReaderSidebarMode: String, CaseIterable, Identifiable {
    case annotations
    case tableOfContents

    var id: String { rawValue }
}

struct EmailReaderSidebarView: View {
    let mode: EmailReaderSidebarMode
    let annotations: [Annotation]
    let onJumpToAnnotation: (Annotation) -> Void
    let onDeleteAnnotation: (UUID) -> Void
    let tocEntries: [TOCPanelEntry]
    let currentSpineIndex: Int
    let onJumpToTOCEntry: (TOCPanelEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: mode == .annotations ? "text.badge.checkmark" : "list.bullet.indent")
                    .foregroundStyle(.secondary)
                Text(mode == .annotations ? "Annotations" : "Contents")
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
            }
        }
        .frame(minWidth: 260, idealWidth: 300)
        .background(.background)
    }
}
