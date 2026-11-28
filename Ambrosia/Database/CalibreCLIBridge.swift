// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SQLite

/// Identifies whether a library is an Ambrosia-managed standalone EPUB folder
/// or a standard Calibre-managed library.
enum LibraryMutationMode: Equatable, Sendable {
    case standalone
    case calibreManaged
}

/// Shared helpers for detecting library layout, resolving `calibredb`,
/// checking whether Calibre desktop GUI is running, and inspecting open readers.
enum CalibreCLIBridge {
    static let calibredbOverrideDefaultsKey = "calibredbCustomPath"
    static let defaultCalibredbPath = "/Applications/calibre.app/Contents/MacOS/calibredb"
    static let calibreBundleIdentifier = "net.kovidgoyal.calibre"

    /// Detects whether `rootURL` is a standalone in-place EPUB folder or a Calibre-managed library.
    static func detectMutationMode(at rootURL: URL) -> LibraryMutationMode {
        let coversDir = rootURL.appendingPathComponent(".covers")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: coversDir.path, isDirectory: &isDir), isDir.boolValue {
            return .standalone
        }

        let dbURL = rootURL.appendingPathComponent("metadata.db")
        if let conn = try? Connection(dbURL.path, readonly: true),
           let count = try? conn.scalar(
               "SELECT COUNT(*) FROM books WHERE LOWER(path) LIKE '%.epub' LIMIT 1"
           ) as? Int64,
           count > 0 {
            return .standalone
        }

        return .calibreManaged
    }

    /// Resolves an executable `calibredb` binary from user override, `/Applications/calibre.app`, or `$PATH`.
    static func resolveCalibredbURL(customPath: String? = nil) -> URL? {
        let fm = FileManager.default
        let override = customPath ?? UserDefaults.standard.string(forKey: calibredbOverrideDefaultsKey)
        var candidates: [String] = []
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(override.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        candidates.append(defaultCalibredbPath)

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("calibredb").path
                if fm.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    /// Returns true if the Calibre desktop GUI is currently running.
    static func isCalibreAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: calibreBundleIdentifier).isEmpty
    }

    /// Returns the set of `calibre_id`s currently open in standalone reader windows or the embedded email reader.
    @MainActor
    static func openReaderBookIDs() -> Set<Int> {
        var ids = ReaderWindowController.openBookIDs()
        if let embeddedID = AppDelegate.shared?.libraryWindowController?
            .libraryViewController?.currentReaderVC?.activeCalibreID {
            ids.insert(embeddedID)
        }
        return ids
    }

    /// Executes `calibredb` off the main actor against `libraryRoot`.
    static func runCalibredb(
        binaryURL: URL,
        libraryRoot: URL,
        arguments: [String]
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["--with-library", libraryRoot.path] + arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, stdout, stderr)
        }.value
    }
}
