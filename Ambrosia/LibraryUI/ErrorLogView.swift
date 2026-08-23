import SwiftUI

/// Simple viewer for `error_log` (see `AmbrosiaMetaDB.recentErrors`), opened
/// alongside the existing Activity Feed rather than merged into it — errors
/// aren't a user-facing "activity" the way sessions/annotations/collection
/// changes are, and most are not book-linked, so they don't fit
/// `ActivityFeedEntry`'s book-centric row model. Presented as a sheet from
/// the same toolbar menu as `CollectionsView`/`ReadingGoalView` (see
/// `LibraryWindowController.makeExportMenu`).
struct ErrorLogView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ErrorLogEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text("Error Log")
                .font(.headline)
            Spacer()
            Button("Clear") { Task { await clear() } }
                .disabled(entries.isEmpty)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No Errors Logged",
                systemImage: "checkmark.circle",
                description: Text("Failures in AO3 extraction, EPUB parsing, and the feed server will appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.subsystem)
                            .font(.subheadline.weight(.semibold))
                        Text(entry.operation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.dateFormatter.string(from: entry.occurredAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.body)
                    if let calibreID = entry.calibreID {
                        Text("Book ID: \(calibreID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    @MainActor
    private func load() async {
        guard let metaDB = session.metaDB else {
            errorMessage = "Open a Calibre library to see the error log."
            isLoading = false
            return
        }
        isLoading = true
        do {
            entries = try await metaDB.recentErrors(limit: 500)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func clear() async {
        guard let metaDB = session.metaDB else { return }
        do {
            try await metaDB.clearErrorLog()
            entries = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
