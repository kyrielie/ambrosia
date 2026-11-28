// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite
import Testing
import ZIPFoundation
@testable import Ambrosia

@Suite("EPUB Import, Pre-Triage, and Safe Trashing")
struct EPUBImportAndTrashTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-import-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct TestEPUBSpec {
        let title: String
        let author: String
        let workID: String
        let chapters: String
        let words: Int
        let updated: String
    }

    private func createMinimalAO3EPUB(at url: URL, spec: TestEPUBSpec) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)

        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(spec.title)</dc:title>
            <dc:creator>\(spec.author)</dc:creator>
            <dc:identifier id="uid">https://archiveofourown.org/works/\(spec.workID)</dc:identifier>
          </metadata>
          <manifest>
            <item id="preface" href="preface.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="preface"/>
          </spine>
        </package>
        """
        let preface = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
          <div class="meta">
            <p class="byline">by <a href="https://archiveofourown.org/users/\(spec.author)">\(spec.author)</a></p>
            <dl class="tags">
              <dt>Stats:</dt>
              <dd>Published: 2026-01-01 Updated: \(spec.updated) Words: \(spec.words) Chapters: \(spec.chapters)</dd>
            </dl>
            <p><a href="https://archiveofourown.org/works/\(spec.workID)">Archive of Our Own</a></p>
          </div>
        </body>
        </html>
        """

        for (path, text) in [("META-INF/container.xml", containerXML), ("content.opf", opf), ("preface.xhtml", preface)] {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data[start..<end]
            }
        }
    }

    // MARK: - Tests

    @Test("Detect standalone vs Calibre-managed mutation modes")
    func testDetectMutationMode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let standaloneDir = dir.appendingPathComponent("standalone")
        try FileManager.default.createDirectory(
            at: standaloneDir.appendingPathComponent(".covers"),
            withIntermediateDirectories: true
        )
        #expect(CalibreCLIBridge.detectMutationMode(at: standaloneDir) == .standalone)

        let calibreDir = dir.appendingPathComponent("calibre")
        try FileManager.default.createDirectory(at: calibreDir, withIntermediateDirectories: true)
        _ = try CalibreLibraryCreator.createEmptyLibrary(at: calibreDir, overwrite: true)
        #expect(CalibreCLIBridge.detectMutationMode(at: calibreDir) == .calibreManaged)
    }

    @Test("Collect EPUB URLs filters non-EPUBs and expands folders")
    func testCollectEPUBURLs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let nested = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let epub1 = dir.appendingPathComponent("one.epub")
        let epub2 = nested.appendingPathComponent("two.epub")
        let txt = dir.appendingPathComponent("ignore.txt")
        try Data("a".utf8).write(to: epub1)
        try Data("b".utf8).write(to: epub2)
        try Data("c".utf8).write(to: txt)

        let collected = EPUBImportTriageEngine.collectEPUBURLs(from: [dir, epub1, txt])
        #expect(collected.count == 2)
        #expect(Set(collected.map(\.lastPathComponent)) == ["one.epub", "two.epub"])
    }

    @Test("Pre-triage classifies new, exact duplicate, newer, and older EPUBs")
    @MainActor
    func testPreTriageClassifications() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let libDir = dir.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let existingEPUB = libDir.appendingPathComponent("work100.epub")
        try createMinimalAO3EPUB(
            at: existingEPUB,
            spec: TestEPUBSpec(
                title: "Starlight", author: "WriterA", workID: "100",
                chapters: "5/10", words: 15_000, updated: "2026-06-01"
            )
        )
        _ = try CalibreLibraryCreator.createEmptyLibrary(at: libDir, overwrite: true)
        let discovered = DiscoveredEPUB(fileURL: existingEPUB, relativePath: "work100.epub", fileSize: 1000)
        _ = try CalibreLibraryWriter.importEPUBs(epubs: [discovered], into: libDir)

        let session = LibrarySession()
        await session.open(url: libDir)
        let metaDB = try #require(session.metaDB)
        var parser = EPUBParser(epubURL: existingEPUB)
        try parser.parse()
        let firstItem = try #require(parser.spine.first)
        let html = try parser.html(for: firstItem, userCSS: "")
        let record = try #require(AO3MetadataExtractor.extract(from: html))
        try await metaDB.insert(record, calibreID: 1)

        let incomingDir = dir.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)

        let exactCopy = incomingDir.appendingPathComponent("exact.epub")
        try FileManager.default.copyItem(at: existingEPUB, to: exactCopy)

        let newerCopy = incomingDir.appendingPathComponent("newer.epub")
        try createMinimalAO3EPUB(
            at: newerCopy,
            spec: TestEPUBSpec(
                title: "Starlight", author: "WriterA", workID: "100",
                chapters: "8/10", words: 24_000, updated: "2026-08-01"
            )
        )

        let olderCopy = incomingDir.appendingPathComponent("older.epub")
        try createMinimalAO3EPUB(
            at: olderCopy,
            spec: TestEPUBSpec(
                title: "Starlight", author: "WriterA", workID: "100",
                chapters: "3/10", words: 9_000, updated: "2026-03-01"
            )
        )

        let brandNew = incomingDir.appendingPathComponent("new.epub")
        try createMinimalAO3EPUB(
            at: brandNew,
            spec: TestEPUBSpec(
                title: "Moonbeam", author: "WriterB", workID: "200",
                chapters: "1/1", words: 3_000, updated: "2026-09-01"
            )
        )

        let (triaged, errors) = await EPUBImportTriageEngine.inspectAndTriage(
            epubURLs: [exactCopy, newerCopy, olderCopy, brandNew],
            session: session
        )
        #expect(errors.isEmpty)
        #expect(triaged.count == 4)

        let byFile = Dictionary(uniqueKeysWithValues: triaged.map { ($0.incoming.url.lastPathComponent, $0) })
        #expect(byFile["exact.epub"]?.category == .exactDuplicate)
        #expect(byFile["exact.epub"]?.recommendedAction == .skip)
        #expect(byFile["newer.epub"]?.category == .newerRevision)
        #expect(byFile["newer.epub"]?.recommendedAction == .updateExisting)
        #expect(byFile["older.epub"]?.category == .olderRevision)
        #expect(byFile["older.epub"]?.recommendedAction == .skip)
        #expect(byFile["new.epub"]?.category == .newBook)
        #expect(byFile["new.epub"]?.recommendedAction == .importNew)

        session.close()
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test("Safe trashing migrates state, cleans derived rows, and removes book")
    @MainActor
    func testSafeTrashMigratesAndCleansUp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let libDir = dir.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let epub1 = libDir.appendingPathComponent("winner.epub")
        let epub2 = libDir.appendingPathComponent("loser.epub")
        try createMinimalAO3EPUB(
            at: epub1,
            spec: TestEPUBSpec(
                title: "Dual", author: "Auth", workID: "555",
                chapters: "10/10", words: 20_000, updated: "2026-05-01"
            )
        )
        try FileManager.default.copyItem(at: epub1, to: epub2)

        _ = try CalibreLibraryCreator.createEmptyLibrary(at: libDir, overwrite: true)
        _ = try CalibreLibraryWriter.importEPUBs(
            epubs: [
                DiscoveredEPUB(fileURL: epub1, relativePath: "winner.epub", fileSize: 1000),
                DiscoveredEPUB(fileURL: epub2, relativePath: "loser.epub", fileSize: 1000)
            ],
            into: libDir
        )

        let session = LibrarySession()
        await session.open(url: libDir)
        let metaDB = try #require(session.metaDB)
        try await metaDB.updateReadingPosition(
            calibreID: 2,
            spineIndex: 4,
            characterOffset: 100,
            scrollOffset: 0.5,
            readPercent: 0.8
        )

        let result = try await CalibreTrashManager.trashBooks(
            winnerByLoserID: [2: 1],
            loserIDs: [2],
            session: session
        )
        #expect(result.trashedIDs == [2])
        #expect(!FileManager.default.fileExists(atPath: epub2.path))
        #expect(FileManager.default.fileExists(atPath: epub1.path))

        let states = await metaDB.bookStates(for: [1, 2])
        #expect(states[1]?.totalReadPercent == 0.8)
        #expect(states[2]?.totalReadPercent == 0.0)

        session.close()
        try? await Task.sleep(for: .milliseconds(50))
    }
}
