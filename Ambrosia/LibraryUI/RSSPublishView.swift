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
                Ambrosia is open. Feeds are unauthenticated: anyone on your \
                local network who knows or guesses a feed URL can read it, \
                not just people you've shared a link with.

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
    let hasSearchSnapshot: Bool
    let initialSnapshotLabel: String?
    let onPublishSearch: () -> Void
    /// Passed the OPML share button's own `NSView` so the caller can anchor
    /// `NSSharingServicePicker` directly to it — anchoring to the sheet's
    /// content view (the previous approach) positioned the popover at the
    /// sheet's corner rather than over the button.
    let onExportOPML: (NSView) -> Void
    let onSaveOPML: () -> Void
    let onStopServer: () -> Void
    let onDone: () -> Void

    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var selected: FeedTarget = .currentSearch
    @State private var copyConfirmation: Bool = false
    @State private var snapshotLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(collections: [(id: String, name: String)],
         baseURL: String,
         hasSearchSnapshot: Bool,
         snapshotLabel: String?,
         onPublishSearch: @escaping () -> Void,
         onExportOPML: @escaping (NSView) -> Void,
         onSaveOPML: @escaping () -> Void,
         onStopServer: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.collections = collections
        self.baseURL = baseURL
        self.hasSearchSnapshot = hasSearchSnapshot
        self.initialSnapshotLabel = snapshotLabel
        self.onPublishSearch = onPublishSearch
        self.onExportOPML = onExportOPML
        self.onSaveOPML = onSaveOPML
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

    private func feedURL(for target: FeedTarget) -> String {
        switch target {
        case .currentSearch:
            return "\(baseURL)/feed/search.xml"
        case .collection(let id, _):
            return "\(baseURL)/feed/collection/\(id).xml"
        case .dailyStory:
            return "\(baseURL)/feed/random-daily.xml"
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
                Button("Save OPML…") {
                    onSaveOPML()
                }
                OPMLShareAnchorButton(title: "Share OPML…", action: onExportOPML)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A push button that hands its own `NSButton` instance back to `action`,
/// instead of firing a plain no-argument closure. Needed specifically for
/// the OPML share button: `NSSharingServicePicker` must be anchored
/// (`show(relativeTo:of:preferredEdge:)`) to the *button that was clicked*
/// to render in the right place — anchoring to an ancestor container (e.g.
/// the sheet's content view, or `.zero` in that view's coordinate space)
/// positions the popover at that container's corner rather than over the
/// button. A plain SwiftUI `Button` has no way to expose the underlying
/// `NSView` it's backed by, so this wraps a real `NSButton` via
/// `NSViewRepresentable` to get a stable, correctly-positioned anchor.
private struct OPMLShareAnchorButton: NSViewRepresentable {
    let title: String
    let action: (NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.fire(_:)))
        button.bezelStyle = .rounded
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        weak var button: NSButton?

        init(action: @escaping (NSView) -> Void) {
            self.action = action
        }

        @objc func fire(_ sender: NSButton) {
            action(sender)
        }
    }
}