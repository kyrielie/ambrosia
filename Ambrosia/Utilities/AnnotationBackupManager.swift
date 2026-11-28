import CryptoKit
import Foundation

/// Automatic lossless per-book JSON snapshot backups (`annotations-snapshot.json`
/// per `calibreID`) stored outside the Calibre library folder under
/// `~/Library/Application Support/Ambrosia/Backups/<library-id>/Annotations/`.
actor AnnotationBackupManager {
    static let shared = AnnotationBackupManager()

    private var debounceTasks: [String: Task<Void, Never>] = [:]

    static func libraryIdentifier(for libraryURL: URL) -> String {
        let digest = SHA256.hash(data: Data(libraryURL.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func backupDirectory(libraryID: String, baseDirectory: URL? = nil) -> URL {
        let appSupport = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Ambrosia", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(libraryID, isDirectory: true)
            .appendingPathComponent("Annotations", isDirectory: true)
    }

    struct BookSnapshot: Codable {
        let calibreID: Int
        let exportedAt: Date
        let annotations: [Annotation]
    }

    func scheduleDirtyBackup(
        calibreID: Int,
        libraryURL: URL,
        metaDB: AmbrosiaMetaDB,
        baseDirectory: URL? = nil
    ) {
        let libID = Self.libraryIdentifier(for: libraryURL)
        let key = "\(libID)-\(calibreID)"
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            try? await flushNow(
                calibreID: calibreID,
                libraryURL: libraryURL,
                metaDB: metaDB,
                baseDirectory: baseDirectory
            )
        }
    }

    func flushNow(
        calibreID: Int,
        libraryURL: URL,
        metaDB: AmbrosiaMetaDB,
        baseDirectory: URL? = nil
    ) async throws {
        let libID = Self.libraryIdentifier(for: libraryURL)
        let annotations = try await metaDB.annotations(for: calibreID)
        let dir = Self.backupDirectory(libraryID: libID, baseDirectory: baseDirectory)
        let fileURL = dir.appendingPathComponent("book-\(calibreID)-annotations-snapshot.json")

        if annotations.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snapshot = BookSnapshot(calibreID: calibreID, exportedAt: Date(), annotations: annotations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    func restoreAllSnapshots(
        libraryURL: URL,
        metaDB: AmbrosiaMetaDB,
        baseDirectory: URL? = nil
    ) async throws -> Int {
        let libID = Self.libraryIdentifier(for: libraryURL)
        let dir = Self.backupDirectory(libraryID: libID, baseDirectory: baseDirectory)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var restoredCount = 0
        for fileURL in files where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let snapshot = try? decoder.decode(BookSnapshot.self, from: data) else { continue }
            for annotation in snapshot.annotations {
                try await metaDB.insertAnnotation(annotation, calibreID: snapshot.calibreID)
                restoredCount += 1
            }
        }
        return restoredCount
    }
}
