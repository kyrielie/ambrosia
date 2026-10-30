// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct DiscoveredEPUB: Sendable, Equatable, Hashable {
    public let fileURL: URL
    public let relativePath: String
    public let fileSize: Int64

    public init(fileURL: URL, relativePath: String, fileSize: Int64) {
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.fileSize = fileSize
    }
}

/// Recursively discovers all EPUB files in a target directory.
public enum EPUBFolderScanner {

    /// Recursively discovers all `.epub` files under `rootURL`.
    /// Skips hidden files/directories (starting with `.`) and system folders.
    public static func scan(rootURL: URL) -> [DiscoveredEPUB] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [DiscoveredEPUB] = []
        let standardRootPath = rootURL.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            let lastComponent = fileURL.lastPathComponent
            // Skip hidden items and common metadata directories
            if lastComponent.hasPrefix(".") || lastComponent == "$RECYCLE.BIN" {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard fileURL.pathExtension.lowercased() == "epub" else { continue }

            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
            guard resourceValues?.isRegularFile == true else { continue }

            let size = Int64(resourceValues?.fileSize ?? 0)
            let standardFilePath = fileURL.standardizedFileURL.path

            var relPath = standardFilePath
            if standardFilePath.hasPrefix(standardRootPath) {
                relPath = String(standardFilePath.dropFirst(standardRootPath.count))
                while relPath.hasPrefix("/") {
                    relPath.removeFirst()
                }
            }

            results.append(DiscoveredEPUB(
                fileURL: fileURL,
                relativePath: relPath,
                fileSize: size
            ))
        }

        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
