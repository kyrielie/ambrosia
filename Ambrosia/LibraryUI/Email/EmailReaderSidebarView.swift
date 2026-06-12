import SwiftUI

enum EmailReaderSidebarMode: String, CaseIterable, Identifiable {
    case annotations

    var id: String { rawValue }
}

struct EmailReaderSidebarView: View {
    let annotations: [Annotation]
    let onJumpToAnnotation: (Annotation) -> Void
    let onDeleteAnnotation: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "text.badge.checkmark")
                    .foregroundStyle(.secondary)
                Text("Annotations")
                    .font(.headline)
                Spacer()
            }
            .padding(12)

            Divider()

            AnnotationSidebarView(
                annotations: annotations,
                onJump: onJumpToAnnotation,
                onDelete: onDeleteAnnotation
            )
        }
        .frame(minWidth: 260, idealWidth: 300)
        .background(.background)
    }
}
