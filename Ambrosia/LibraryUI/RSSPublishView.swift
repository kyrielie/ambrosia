import SwiftUI

// MARK: - RSSPublishWarningView
//
// Shown before the RSS server starts (or before re-publishing all collection
// feeds). Two choices: Publish (start server, show ManageFeedsView) or Cancel.
// No target picker — publishing is all-or-nothing for collections.

struct RSSPublishWarningView: View {
    let onPublish: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var prefs = ReaderPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start RSS Feed Server?")
                .font(.headline)

            Text("""
                The feed server runs a local HTTP server on this Mac while \
                Ambrosia is open. Feed URLs include a private token, so only \
                devices you've shared a link with can read your feeds — but \
                anyone with a link can, so treat it like a password.

                All collections will be published as live feeds that update \
                immediately whenever collection membership changes. You can \
                exclude specific collections in Preferences > Data after \
                starting the server.

                Feed URLs are tied to this Mac's current local network address. \
                They may stop working if you change networks or restart the server.
                """)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Restart automatically when I reopen this library",
                   isOn: $prefs.feedServerAutoRestart)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start Server", action: onPublish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - ManageFeedsView
//
// Shown while the server is running. Presents a picker of all feed URLs with
// a visible, selectable URL string and a Copy button. Also allows publishing
// a frozen current-search snapshot, exporting OPML, and stopping the server.

struct ManageFeedsView: View {

    enum FeedTarget: Hashable {
        case currentSearch
        case collection(id: String, name: String)
        case dailyStory

        var displayName: String {
            switch self {
            case .currentSearch:         return "Current Search (snapshot)"
            case .collection(_, let n):  return n
            case .dailyStory:            return "Daily Story"
            }
        }
    }

    let collections: [(id: String, name: String)]
    let baseURL: String
    /// Shared-secret token required by every route on the server. Appended
    /// to every displayed/copied feed URL so subscribing apps authenticate
    /// automatically; see LocalFeedServer's `isAuthorized`.
    let authToken: String
    let hasSearchSnapshot: Bool
    let initialSnapshotLabel: String?
    let onPublishSearch: () -> Void
    let onExportOPML: () -> Void
    let onStopServer: () -> Void
    let onDone: () -> Void

    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var selected: FeedTarget = .currentSearch
    @State private var copyConfirmation: Bool = false
    @State private var snapshotLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(collections: [(id: String, name: String)],
         baseURL: String,
         authToken: String,
         hasSearchSnapshot: Bool,
         snapshotLabel: String?,
         onPublishSearch: @escaping () -> Void,
         onExportOPML: @escaping () -> Void,
         onStopServer: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.collections = collections
        self.baseURL = baseURL
        self.authToken = authToken
        self.hasSearchSnapshot = hasSearchSnapshot
        self.initialSnapshotLabel = snapshotLabel
        self.onPublishSearch = onPublishSearch
        self.onExportOPML = onExportOPML
        self.onStopServer = onStopServer
        self.onDone = onDone
        _snapshotLabel = State(initialValue: snapshotLabel)
    }

    private var availableTargets: [FeedTarget] {
        var targets: [FeedTarget] = [.currentSearch]
        targets += collections.map { FeedTarget.collection(id: $0.id, name: $0.name) }
        if prefs.feedServerEnableDailyStory {
            targets.append(.dailyStory)
        }
        return targets
    }

    private var tokenSuffix: String {
        authToken.isEmpty ? "" : "?token=\(authToken)"
    }

    private func feedURL(for target: FeedTarget) -> String {
        switch target {
        case .currentSearch:
            return "\(baseURL)/feed/search.xml\(tokenSuffix)"
        case .collection(let id, _):
            return "\(baseURL)/feed/collection/\(id).xml\(tokenSuffix)"
        case .dailyStory:
            return "\(baseURL)/feed/random-daily.xml\(tokenSuffix)"
        }
    }

    private var selectedURL: String { feedURL(for: selected) }

    private var isExcluded: Bool {
        if case .collection(let id, _) = selected {
            return prefs.feedServerExcludedCollectionIDs.contains(id)
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Feeds")
                .font(.headline)

            // Feed picker
            Picker("Feed", selection: $selected) {
                ForEach(availableTargets, id: \.self) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()

            // Excluded warning
            if isExcluded {
                Label("This collection is excluded from publishing. Enable it in Preferences > Data.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // URL display + copy
            HStack(spacing: 8) {
                Text(selectedURL)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(isExcluded ? .secondary : .primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button(copyConfirmation ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectedURL, forType: .string)
                    if reduceMotion {
                        copyConfirmation = true
                    } else {
                        withAnimation { copyConfirmation = true }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if reduceMotion {
                            copyConfirmation = false
                        } else {
                            withAnimation { copyConfirmation = false }
                        }
                    }
                }
                .disabled(isExcluded)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            // Publish Search action (only relevant for the search target)
            if case .currentSearch = selected {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Publish Current Search") {
                        onPublishSearch()
                        // onPublishSearch is async work on the caller's side (it writes
                        // the snapshot then the caller re-presents this sheet), so the
                        // label shown here is just optimistic UI until the next reload;
                        // the caller passes the authoritative label back in via
                        // `snapshotLabel` on next sheet presentation.
                    }
                    if let label = snapshotLabel {
                        Text("Last snapshot: \"\(label)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No snapshot published yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Footer actions
            HStack {
                Button("Stop Server") {
                    onStopServer()
                }
                .foregroundStyle(.red)
                Button("Export OPML…") {
                    onExportOPML()
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
