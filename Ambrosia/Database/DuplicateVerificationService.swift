// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import ZIPFoundation

/// Classification of how a duplicate EPUB file compares to the cluster winner.
enum DuplicateMatchTier: String, Sendable, Equatable {
    case exactFileMatch = "Exact Match (SHA-256)"
    case contentMatch = "Same Content (ZIP)"
    case differentEdition = "Different Edition"
    case sameInode = "Same File (Hardlink)"
    case missingFile = "Missing File"
}

/// Content signature entry for comparing EPUB archives independently of ZIP wrapper metadata.
struct EPUBContentSignatureEntry: Hashable, Sendable {
    let uncompressedSize: UInt64
    let crc32: CRC32
}

/// Verifies whether candidate duplicate EPUB files are byte-identical (`SHA-256`),
/// content-identical (`ZIP CRC-32` over story/image entries), or merged anthologies.
enum DuplicateVerificationService {

    /// Streams a file in 512 KB chunks and returns its lowercase hex SHA-256 digest.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 512 * 1024
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the file size in bytes if the file exists and is readable.
    static func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    /// True if both URLs point to the exact same physical file on disk (same inode / hardlink).
    static func isSamePhysicalFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL == rhs.standardizedFileURL { return true }
        guard let leftID = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let rightID = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return leftID.isEqual(rightID)
    }

    /// Inspects the EPUB's ZIP central directory to detect multi-work merged anthologies (`1/...` and `2/...`).
    static func isAnthologyArchive(at url: URL) -> Bool {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            return false
        }
        var hasPart1 = false
        var hasPart2 = false
        for entry in archive {
            if entry.path.hasPrefix("1/") { hasPart1 = true }
            if entry.path.hasPrefix("2/") { hasPart2 = true }
            if hasPart1 && hasPart2 { return true }
        }
        return false
    }

    /// Builds a normalized map of `(path -> (uncompressedSize, crc32))` for story/image entries,
    /// ignoring volatile wrapper entries (`calibre_bookmarks.txt`, `mimetype`, `.opf`).
    static func zipContentSignature(of url: URL) -> [String: EPUBContentSignatureEntry]? {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            return nil
        }
        var map: [String: EPUBContentSignatureEntry] = [:]
        for entry in archive where entry.type == .file {
            let path = entry.path
            if path == "mimetype"
                || path == "META-INF/calibre_bookmarks.txt"
                || path.hasSuffix(".opf") {
                continue
            }
            map[path] = EPUBContentSignatureEntry(
                uncompressedSize: entry.uncompressedSize,
                crc32: entry.checksum
            )
        }
        return map
    }

    /// Classifies each loser URL against `winnerURL` using size pre-filtering,
    /// same-inode checks, streaming SHA-256, and ZIP CRC-32 content comparison.
    static func verifyCluster(
        winnerURL: URL?,
        loserURLs: [Int: URL?]
    ) -> [Int: DuplicateMatchTier] {
        guard let winnerURL,
              FileManager.default.fileExists(atPath: winnerURL.path) else {
            return loserURLs.mapValues { _ in .missingFile }
        }

        let winnerSize = fileSize(of: winnerURL)
        var cachedWinnerSHA: String?
        var cachedWinnerSig: [String: EPUBContentSignatureEntry]?
        var didComputeWinnerSig = false

        var results: [Int: DuplicateMatchTier] = [:]
        for (loserID, maybeURL) in loserURLs {
            guard let loserURL = maybeURL,
                  FileManager.default.fileExists(atPath: loserURL.path) else {
                results[loserID] = .missingFile
                continue
            }

            if isSamePhysicalFile(winnerURL, loserURL) {
                results[loserID] = .sameInode
                continue
            }

            if let winnerSize, let loserSize = fileSize(of: loserURL), winnerSize == loserSize {
                if cachedWinnerSHA == nil {
                    cachedWinnerSHA = try? sha256(of: winnerURL)
                }
                if let wSHA = cachedWinnerSHA,
                   let lSHA = try? sha256(of: loserURL),
                   wSHA == lSHA {
                    results[loserID] = .exactFileMatch
                    continue
                }
            }

            if !didComputeWinnerSig {
                cachedWinnerSig = zipContentSignature(of: winnerURL)
                didComputeWinnerSig = true
            }
            if let wSig = cachedWinnerSig,
               let lSig = zipContentSignature(of: loserURL),
               !wSig.isEmpty,
               wSig == lSig {
                results[loserID] = .contentMatch
                continue
            }

            results[loserID] = .differentEdition
        }

        return results
    }
}
