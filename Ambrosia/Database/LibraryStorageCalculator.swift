// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite

public struct LibraryStorageBreakdown: Sendable, Equatable {
    public let epubsSizeBytes: Int64
    public let calibreDBSizeBytes: Int64
    public let ftsDBSizeBytes: Int64
    public let ambrosiaMetaDBSizeBytes: Int64
    public let totalSizeBytes: Int64

    public init(
        epubsSizeBytes: Int64,
        calibreDBSizeBytes: Int64,
        ftsDBSizeBytes: Int64,
        ambrosiaMetaDBSizeBytes: Int64
    ) {
        self.epubsSizeBytes = epubsSizeBytes
        self.calibreDBSizeBytes = calibreDBSizeBytes
        self.ftsDBSizeBytes = ftsDBSizeBytes
        self.ambrosiaMetaDBSizeBytes = ambrosiaMetaDBSizeBytes
        self.totalSizeBytes = epubsSizeBytes + calibreDBSizeBytes + ftsDBSizeBytes + ambrosiaMetaDBSizeBytes
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter
    }()

    public var formattedTotal: String { Self.byteFormatter.string(fromByteCount: totalSizeBytes) }
    public var formattedTotalSize: String { formattedTotal }
    public var formattedEpubsSize: String { Self.byteFormatter.string(fromByteCount: epubsSizeBytes) }
    public var formattedCalibreDBSize: String { Self.byteFormatter.string(fromByteCount: calibreDBSizeBytes) }
    public var formattedFTSDBSize: String { Self.byteFormatter.string(fromByteCount: ftsDBSizeBytes) }
    public var formattedAmbrosiaMetaDBSize: String { Self.byteFormatter.string(fromByteCount: ambrosiaMetaDBSizeBytes) }

    public static func combining(_ breakdowns: [LibraryStorageBreakdown]) -> LibraryStorageBreakdown {
        LibraryStorageBreakdown(
            epubsSizeBytes: breakdowns.reduce(0) { $0 + $1.epubsSizeBytes },
            calibreDBSizeBytes: breakdowns.reduce(0) { $0 + $1.calibreDBSizeBytes },
            ftsDBSizeBytes: breakdowns.reduce(0) { $0 + $1.ftsDBSizeBytes },
            ambrosiaMetaDBSizeBytes: breakdowns.reduce(0) { $0 + $1.ambrosiaMetaDBSizeBytes }
        )
    }

    public var proportions: (epubs: Double, fts: Double, calibre: Double, ambrosia: Double) {
        guard totalSizeBytes > 0 else { return (0, 0, 0, 0) }
        let total = Double(totalSizeBytes)
        return (
            epubs: Double(epubsSizeBytes) / total,
            fts: Double(ftsDBSizeBytes) / total,
            calibre: Double(calibreDBSizeBytes) / total,
            ambrosia: Double(ambrosiaMetaDBSizeBytes) / total
        )
    }
}

public enum LibraryStorageCalculator {

    /// Calculates storage breakdown for a library at `libraryURL`.
    public static func calculate(libraryURL: URL) async -> LibraryStorageBreakdown {
        let epubsSize = await calculateEpubsSize(libraryURL: libraryURL)
        let calibreDBSize = calculateDatabaseSize(
            baseFileURL: libraryURL.appendingPathComponent("metadata.db")
        )
        let ftsDBSize = calculateDatabaseSize(
            baseFileURL: libraryURL.appendingPathComponent("full-text-search.db")
        )

        var ambrosiaDBSize: Int64 = 0
        let hash = Ambrosia.libraryHash(for: libraryURL)
        if let dir = try? AmbrosiaMetaDB.databaseDirectory(for: hash) {
            let metaURL = dir.appendingPathComponent("ambrosia_meta.db")
            ambrosiaDBSize = calculateDatabaseSize(baseFileURL: metaURL)
        }

        return LibraryStorageBreakdown(
            epubsSizeBytes: epubsSize,
            calibreDBSizeBytes: calibreDBSize,
            ftsDBSizeBytes: ftsDBSize,
            ambrosiaMetaDBSizeBytes: ambrosiaDBSize
        )
    }

    /// Convenience overload taking `for:`.
    public static func calculate(for libraryURL: URL) async -> LibraryStorageBreakdown {
        await calculate(libraryURL: libraryURL)
    }

    private static func calculateDatabaseSize(baseFileURL: URL) -> Int64 {
        var total: Int64 = 0
        let paths = [
            baseFileURL,
            baseFileURL.deletingPathExtension().appendingPathExtension("db-wal"),
            baseFileURL.deletingPathExtension().appendingPathExtension("db-shm")
        ]

        let fm = FileManager.default
        for url in paths {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    private static func calculateEpubsSize(libraryURL: URL) async -> Int64 {
        let dbURL = libraryURL.appendingPathComponent("metadata.db")
        if let conn = try? Connection(dbURL.path, readonly: true) {
            if let sumVal = (try? conn.scalar("SELECT sum(uncompressed_size) FROM data WHERE format = 'EPUB'")) as? Int64,
               sumVal > 0 {
                return sumVal
            }
        }

        // Fallback: directory walk for .epub files
        return await Task.detached(priority: .utility) {
            var sum: Int64 = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: libraryURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return 0 }

            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "epub" {
                if let vals = try? fileURL.resourceValues(forKeys: Set(keys)),
                   vals.isRegularFile == true,
                   let size = vals.fileSize {
                    sum += Int64(size)
                }
            }
            return sum
        }.value
    }
}
