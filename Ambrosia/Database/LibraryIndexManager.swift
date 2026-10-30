import Foundation
import SQLite

struct LibraryIndexEntry: Codable, Identifiable, Equatable {
    var id: String { hash }
    var hash: String
    var lastKnownPath: String
    var displayName: String
    var lastOpened: String
    var bookmarkData: Data?
    var calibreUUID: String?
}

final class LibraryIndexManager {
    static let shared = LibraryIndexManager()

    private let iso = ISO8601DateFormatter()
    private let fm = FileManager.default

    /// Overrides `AmbrosiaMetaDB.librariesBaseDirectory()` for tests, so the
    /// real `index.json` under Application Support (and real library
    /// directories `relink` would otherwise move) are never touched by a
    /// test run. `nil` (the default, used by `.shared`) means "use the real
    /// directory" as before.
    private let directoryOverride: URL?

    private init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    /// Test-only entry point: an instance scoped to `directory` instead of
    /// the real Application Support path. Every read/write below routes
    /// through `librariesBaseDirectory()`, which honors this override, so a
    /// test instance never touches a developer's real index.json or moves a
    /// real library directory.
    static func makeForTesting(directory: URL) -> LibraryIndexManager {
        LibraryIndexManager(directoryOverride: directory)
    }

    private func librariesBaseDirectory() throws -> URL {
        if let directoryOverride {
            try fm.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            return directoryOverride
        }
        return try AmbrosiaMetaDB.librariesBaseDirectory()
    }

    func entries() -> [LibraryIndexEntry] {
        guard let data = try? Data(contentsOf: indexURL()) else { return [] }
        return (try? JSONDecoder().decode([LibraryIndexEntry].self, from: data)) ?? []
    }

    func record(url: URL) {
        let hash = libraryHash(for: url)
        var current = entries()
        let bookmark = try? url.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let uuid = Self.fetchCalibreUUID(libraryURL: url)
        let entry = LibraryIndexEntry(
            hash: hash,
            lastKnownPath: url.resolvingSymlinksInPath().path,
            displayName: url.lastPathComponent,
            lastOpened: iso.string(from: Date()),
            bookmarkData: bookmark,
            calibreUUID: uuid
        )

        if let index = current.firstIndex(where: { $0.hash == hash }) {
            current[index] = entry
        } else {
            current.append(entry)
        }
        write(current)
    }

    func update(oldHash: String, newHash: String, newURL: URL) {
        var current = entries()
        let bookmark = try? newURL.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let uuid = Self.fetchCalibreUUID(libraryURL: newURL)
        let entry = LibraryIndexEntry(
            hash: newHash,
            lastKnownPath: newURL.resolvingSymlinksInPath().path,
            displayName: newURL.lastPathComponent,
            lastOpened: iso.string(from: Date()),
            bookmarkData: bookmark,
            calibreUUID: uuid
        )

        current.removeAll { $0.hash == oldHash || $0.hash == newHash }
        current.append(entry)
        write(current)
    }

    func updateEntry(_ entry: LibraryIndexEntry) {
        var current = entries()
        if let idx = current.firstIndex(where: { $0.hash == entry.hash }) {
            current[idx] = entry
            write(current)
        }
    }

    /// Removes a library entry by hash from index.json.
    /// If `deleteAppSupportMetadata` is true, also deletes the cached metadata folder under Application Support/Ambrosia/libraries/<hash>.
    func remove(hash: String, deleteAppSupportMetadata: Bool = false) {
        var current = entries()
        current.removeAll { $0.hash == hash }
        write(current)

        if deleteAppSupportMetadata {
            do {
                let dir = try librariesBaseDirectory().appendingPathComponent(hash)
                if fm.fileExists(atPath: dir.path) {
                    try fm.removeItem(at: dir)
                }
            } catch {
                #if DEBUG
                print("[LibraryIndexManager] Failed to remove metadata directory for \(hash): \(error)")
                #endif
            }
        }
    }

    /// Resolves the current URL for a library entry, checking `lastKnownPath` first,
    /// then resolving the persistent macOS URL bookmark if the folder was renamed or moved.
    func resolveURL(for entry: LibraryIndexEntry) -> URL? {
        let dbPath = URL(fileURLWithPath: entry.lastKnownPath).appendingPathComponent("metadata.db").path
        if fm.isReadableFile(atPath: dbPath) {
            return URL(fileURLWithPath: entry.lastKnownPath)
        }

        // Try resolving persistent URL bookmark
        guard let data = entry.bookmarkData else { return nil }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        let resolvedDB = resolved.appendingPathComponent("metadata.db").path
        guard fm.isReadableFile(atPath: resolvedDB) else { return nil }

        // Bookmark resolved to moved/renamed path!
        var updated = entry
        updated.lastKnownPath = resolved.path
        if isStale {
            updated.bookmarkData = try? resolved.bookmarkData(
                options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        updateEntry(updated)
        return resolved
    }

    static func fetchCalibreUUID(libraryURL: URL) -> String? {
        let dbURL = libraryURL.appendingPathComponent("metadata.db")
        guard let conn = try? Connection(dbURL.path, readonly: true) else { return nil }
        return (try? conn.scalar("SELECT uuid FROM library_id LIMIT 1")) as? String
    }

    /// Searches the specified parent directories for a Calibre library with the given UUID.
    func findLibrary(withUUID uuid: String, inSearchDirectories directories: [URL]) -> URL? {
        for dir in directories {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "metadata.db" {
                let folderURL = fileURL.deletingLastPathComponent()
                if Self.fetchCalibreUUID(libraryURL: folderURL) == uuid {
                    return folderURL
                }
            }
        }
        return nil
    }

    func relink(oldHash: String, newLibraryURL: URL) throws {
        let newHash = libraryHash(for: newLibraryURL)
        let base = try librariesBaseDirectory()
        let oldDir = base.appendingPathComponent(oldHash)
        let newDir = base.appendingPathComponent(newHash)
        if fm.fileExists(atPath: newDir.path) {
            try fm.removeItem(at: newDir)
        }
        try fm.moveItem(at: oldDir, to: newDir)
        update(oldHash: oldHash, newHash: newHash, newURL: newLibraryURL)
    }

    private func indexURL() -> URL {
        do {
            return try librariesBaseDirectory().appendingPathComponent("index.json")
        } catch {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            return support.appendingPathComponent("Ambrosia").appendingPathComponent("libraries").appendingPathComponent("index.json")
        }
    }

    private func write(_ entries: [LibraryIndexEntry]) {
        let url = indexURL()
        let tmp = url.appendingPathExtension("tmp")
        do {
            let data = try JSONEncoder().encode(entries.sorted { $0.lastOpened > $1.lastOpened })
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.moveItem(at: tmp, to: url)
        } catch {
            #if DEBUG
            print("[LibraryIndexManager] Write failed: \(error)")
            #endif
        }
    }
}
