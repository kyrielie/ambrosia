// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine

@MainActor
final class VolumeMonitor {
    static let shared = VolumeMonitor()

    private var cancellables: Set<AnyCancellable> = []
    private weak var session: LibrarySession?

    private init() {}

    func startMonitoring(session: LibrarySession) {
        self.session = session
        guard cancellables.isEmpty else { return }

        let ws = NSWorkspace.shared.notificationCenter

        ws.publisher(for: NSWorkspace.willUnmountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                self?.handleVolumeUnmounting(notif)
            }
            .store(in: &cancellables)

        ws.publisher(for: NSWorkspace.didUnmountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                self?.handleVolumeUnmounting(notif)
            }
            .store(in: &cancellables)

        ws.publisher(for: NSWorkspace.didMountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                self?.handleVolumeMounted(notif)
            }
            .store(in: &cancellables)
    }

    private func handleVolumeUnmounting(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        session?.handleActiveVolumeDisconnected(volumeURL: volumeURL)
    }

    private func handleVolumeMounted(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        guard let session else { return }

        if session.isVolumeDisconnected, let path = LibraryRegistry.shared.activePath {
            if path.hasPrefix(volumeURL.path) {
                let libraryURL = URL(fileURLWithPath: path)
                let dbPath = libraryURL.appendingPathComponent("metadata.db").path
                if FileManager.default.isReadableFile(atPath: dbPath) {
                    Task { await session.handleVolumeReconnected(libraryURL: libraryURL) }
                    return
                }
            }
        }

        // Also check if any known library on this volume can now be resolved
        let entries = LibraryIndexManager.shared.entries()
        for entry in entries where entry.lastKnownPath.hasPrefix(volumeURL.path) {
            if let resolved = LibraryIndexManager.shared.resolveURL(for: entry),
               entry.lastKnownPath == LibraryRegistry.shared.activePath {
                Task { await session.handleVolumeReconnected(libraryURL: resolved) }
                break
            }
        }
    }
}
