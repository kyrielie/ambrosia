import Foundation

struct LibraryIndexEntry: Codable, Identifiable, Equatable {
    var id: String { hash }
    var hash: String
    var lastKnownPath: String
    var displayName: String
    var lastOpened: String
}

final class LibraryIndexManager {
    static let shared = LibraryIndexManager()

    private let iso = ISO8601DateFormatter()
    private let fm = FileManager.default

    private init() {}

    func entries() -> [LibraryIndexEntry] {
        guard let data = try? Data(contentsOf: indexURL()) else { return [] }
        return (try? JSONDecoder().decode([LibraryIndexEntry].self, from: data)) ?? []
    }

    func record(url: URL) {
        let hash = libraryHash(for: url)
        var current = entries()
        let entry = LibraryIndexEntry(
            hash: hash,
            lastKnownPath: url.resolvingSymlinksInPath().path,
            displayName: url.lastPathComponent,
            lastOpened: iso.string(from: Date())
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
        let entry = LibraryIndexEntry(
            hash: newHash,
            lastKnownPath: newURL.resolvingSymlinksInPath().path,
            displayName: newURL.lastPathComponent,
            lastOpened: iso.string(from: Date())
        )

        current.removeAll { $0.hash == oldHash || $0.hash == newHash }
        current.append(entry)
        write(current)
    }

    func relink(oldHash: String, newLibraryURL: URL) throws {
        let newHash = libraryHash(for: newLibraryURL)
        let base = try AmbrosiaMetaDB.librariesBaseDirectory()
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
            return try AmbrosiaMetaDB.librariesBaseDirectory().appendingPathComponent("index.json")
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
