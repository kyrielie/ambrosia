// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SQLite
import ZIPFoundation
@testable import Ambrosia

final class StandaloneCalibreTests: XCTestCase {

    // MARK: - 1. CalibreFunctions Tests

    func testTitleSort() {
        XCTAssertEqual(CalibreFunctions.titleSort("The Lightning Thief"), "Lightning Thief, The")
        XCTAssertEqual(CalibreFunctions.titleSort("A Day in the Life"), "Day in the Life, A")
        XCTAssertEqual(CalibreFunctions.titleSort("An Apple"), "Apple, An")
        XCTAssertEqual(CalibreFunctions.titleSort("the hobbit"), "hobbit, the")
        XCTAssertEqual(CalibreFunctions.titleSort("Percy Jackson"), "Percy Jackson")
        XCTAssertEqual(CalibreFunctions.titleSort("   The Odyssey   "), "Odyssey, The")
    }

    func testAuthorSort() {
        XCTAssertEqual(CalibreFunctions.authorSort("Rick Riordan"), "Riordan, Rick")
        XCTAssertEqual(CalibreFunctions.authorSort("Homer"), "Homer")
        XCTAssertEqual(CalibreFunctions.authorSort("Martin Luther King Jr."), "King Jr., Martin Luther")
        XCTAssertEqual(CalibreFunctions.authorSort("John Doe Ph.D."), "Doe Ph.D., John")
        XCTAssertEqual(CalibreFunctions.authorSort(of: ["Rick Riordan", "Mark Oshiro"]), "Riordan, Rick & Oshiro, Mark")
    }

    func testFilenameSafe() {
        XCTAssertEqual(CalibreFunctions.filenameSafe("Percy Jackson: The Sea of Monsters?"), "Percy Jackson The Sea of Monsters")
        XCTAssertEqual(CalibreFunctions.filenameSafe("Café & Résumé/Test"), "Cafe & Resume Test")
        XCTAssertEqual(CalibreFunctions.filenameSafe("It's a test: \"quotes\""), "It's a test quotes")
        XCTAssertEqual(CalibreFunctions.filenameSafe("Curly: “quotes”"), "Curly 'quotes'")
    }

    func testRegisteredSQLiteFunctions() throws {
        let conn = try Connection(.inMemory)
        CalibreFunctions.register(on: conn)

        let titleResult = try conn.scalar("SELECT title_sort('The Hobbit')") as? String
        XCTAssertEqual(titleResult, "Hobbit, The")

        let uuidResult = try conn.scalar("SELECT uuid4()") as? String
        XCTAssertNotNil(uuidResult)
        XCTAssertEqual(uuidResult?.count, 36)
    }

    // MARK: - 2. CalibreLibraryCreator Tests

    func testCreateEmptyLibrary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let conn = try CalibreLibraryCreator.createEmptyLibrary(at: tempDir)

        let version = try conn.scalar("PRAGMA user_version") as? Int64
        XCTAssertEqual(version, 26)

        let libUUID = try conn.scalar("SELECT uuid FROM library_id LIMIT 1") as? String
        XCTAssertNotNil(libUUID)

        // Verify trigger title_sort and uuid4 work on insert
        try conn.run("INSERT INTO books (title) VALUES (?)", "The Lightning Thief")
        let row = try conn.prepare("SELECT sort, uuid FROM books WHERE id = 1").map { $0 }.first
        XCTAssertEqual(row?[0] as? String, "Lightning Thief, The")
        XCTAssertNotNil(row?[1] as? String)
    }

    // MARK: - 3. EPUBFolderScanner Tests

    func testEPUBFolderScanner() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a subfolder with epubs and hidden files
        let subDir = tempDir.appendingPathComponent("SubFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let epub1 = tempDir.appendingPathComponent("Book1.epub")
        let epub2 = subDir.appendingPathComponent("Book2.epub")
        let hidden = tempDir.appendingPathComponent(".hidden.epub")
        let txt = tempDir.appendingPathComponent("notes.txt")

        try "dummy1".write(to: epub1, atomically: true, encoding: .utf8)
        try "dummy2".write(to: epub2, atomically: true, encoding: .utf8)
        try "hidden".write(to: hidden, atomically: true, encoding: .utf8)
        try "notes".write(to: txt, atomically: true, encoding: .utf8)

        let discovered = EPUBFolderScanner.scan(rootURL: tempDir)
        XCTAssertEqual(discovered.count, 2)
        XCTAssertEqual(discovered[0].relativePath, "Book1.epub")
        XCTAssertEqual(discovered[1].relativePath, "SubFolder/Book2.epub")
    }

    // MARK: - 4. Ingestion & In-Place Query Integration Tests

    func testFullStandaloneIngestionAndFTS() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("full_ingestion_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Create synthetic EPUB files inside nested subfolders
        let authorDir1 = tempDir.appendingPathComponent("Rick Riordan", isDirectory: true)
        try FileManager.default.createDirectory(at: authorDir1, withIntermediateDirectories: true)
        let epubURL1 = authorDir1.appendingPathComponent("The Lightning Thief.epub")

        let spec1 = SyntheticEPUBSpec(
            title: "The Lightning Thief",
            creator: "Rick Riordan",
            subjects: ["Greek Mythology", "Demigods"],
            description: "Percy Jackson discovers he is the son of Poseidon.",
            bodyHTML: "<p>Look, I did not want to be a half-blood. Being a half-blood is dangerous.</p>"
        )
        try createSyntheticEPUB(at: epubURL1, spec: spec1)

        let authorDir2 = tempDir.appendingPathComponent("Homer", isDirectory: true)
        try FileManager.default.createDirectory(at: authorDir2, withIntermediateDirectories: true)
        let epubURL2 = authorDir2.appendingPathComponent("The Odyssey.epub")

        let spec2 = SyntheticEPUBSpec(
            title: "The Odyssey",
            creator: "Homer",
            subjects: ["Epic Poetry", "Classics"],
            description: "The journey of Odysseus.",
            bodyHTML: "<p>Sing in me, Muse, and through me tell the story of that man skilled in all ways.</p>"
        )
        try createSyntheticEPUB(at: epubURL2, spec: spec2)

        // 2. Scan and import into a newly created Calibre library
        let discovered = EPUBFolderScanner.scan(rootURL: tempDir)
        XCTAssertEqual(discovered.count, 2)

        try CalibreLibraryCreator.createEmptyLibrary(at: tempDir)
        let imported = try CalibreLibraryWriter.importEPUBs(epubs: discovered, into: tempDir)
        XCTAssertEqual(imported, 2)

        // Verify incremental rescan skips already-imported books
        let rescanImported = try CalibreLibraryWriter.importEPUBs(epubs: discovered, into: tempDir)
        XCTAssertEqual(rescanImported, 0)

        // 3. Verify CalibreLibrary can open and read the library
        let library = try CalibreLibrary(root: tempDir)
        let count = await library.bookCount()
        XCTAssertEqual(count, 2)

        let books = await library.books(offset: 0, limit: 10, sort: .title, ascending: true)
        XCTAssertEqual(books.count, 2)

        guard let firstBook = books.first(where: { $0.title == "The Lightning Thief" }),
              let secondBook = books.first(where: { $0.title == "The Odyssey" }) else {
            XCTFail("Expected both books to be fetched")
            return
        }

        XCTAssertEqual(firstBook.displayAuthors, "Rick Riordan")
        XCTAssertTrue(firstBook.tags.contains("Greek Mythology"))
        XCTAssertEqual(secondBook.displayAuthors, "Homer")
        XCTAssertTrue(secondBook.tags.contains("Epic Poetry"))

        // 4. Verify path resolution (Phase 2)
        let resolvedURL1 = firstBook.epubURL(libraryRoot: tempDir)
        XCTAssertNotNil(resolvedURL1)
        XCTAssertEqual(resolvedURL1?.standardizedFileURL.path, epubURL1.standardizedFileURL.path)

        let resolvedURL2 = secondBook.epubURL(libraryRoot: tempDir)
        XCTAssertNotNil(resolvedURL2)
        XCTAssertEqual(resolvedURL2?.standardizedFileURL.path, epubURL2.standardizedFileURL.path)

        let libResolvedURL1 = await library.epubURL(calibreID: firstBook.id)
        XCTAssertNotNil(libResolvedURL1)
        XCTAssertEqual(libResolvedURL1?.standardizedFileURL.path, epubURL1.standardizedFileURL.path)

        // 5. Index text into full-text-search.db and verify FTS query
        let indexedCount = try CalibreFTSWriter.indexLibrary(at: tempDir)
        XCTAssertEqual(indexedCount, 2)

        guard let fts = CalibreFTSLibrary(libraryURL: tempDir) else {
            XCTFail("Failed to open CalibreFTSLibrary")
            return
        }

        guard let query1 = FTSQuery.make("half-blood", formats: ["EPUB"]),
              let query2 = FTSQuery.make("Muse", formats: ["EPUB"]) else {
            XCTFail("Failed to make FTSQuery")
            return
        }

        let token1 = fts.beginSearch()
        let searchResult1 = try await fts.searchBooks(query1, token: token1)
        XCTAssertEqual(searchResult1.bookIDs, [firstBook.id])

        let snippets1 = try await fts.snippets(bookID: firstBook.id, query: query1, token: token1)
        XCTAssertFalse(snippets1.isEmpty)
        XCTAssertTrue(snippets1[0].text.contains("half-blood"))

        let token2 = fts.beginSearch()
        let searchResult2 = try await fts.searchBooks(query2, token: token2)
        XCTAssertEqual(searchResult2.bookIDs, [secondBook.id])

        let snippets2 = try await fts.snippets(bookID: secondBook.id, query: query2, token: token2)
        XCTAssertFalse(snippets2.isEmpty)
        XCTAssertTrue(snippets2[0].text.contains("Muse"))

        // 6. Compact & vacuum FTS database, verifying integrity and searchability afterwards
        let (reclaimed, ftsAfter) = try CalibreFTSWriter.compactAndVacuum(libraryURL: tempDir)
        XCTAssertGreaterThanOrEqual(reclaimed, 0)
        XCTAssertGreaterThan(ftsAfter, 0)

        let token3 = fts.beginSearch()
        let searchResult3 = try await fts.searchBooks(query1, token: token3)
        XCTAssertEqual(searchResult3.bookIDs, [firstBook.id])
    }

    // MARK: - Synthetic EPUB Helper

    private struct SyntheticEPUBSpec {
        let title: String
        let creator: String
        let subjects: [String]
        let description: String
        let bodyHTML: String
    }

    private func createSyntheticEPUB(at url: URL, spec: SyntheticEPUBSpec) throws {
        let archive = try Archive(url: url, accessMode: .create)

        let mimetype = Data("application/epub+zip".utf8)
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: UInt32(mimetype.count), compressionMethod: .none) { position, size in
            mimetype.subdata(in: position..<(position + size))
        }

        let containerXML = Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8)
        try archive.addEntry(with: "META-INF/container.xml", type: .file, uncompressedSize: UInt32(containerXML.count), compressionMethod: .none) { pos, size in
            containerXML.subdata(in: pos..<(pos + size))
        }

        let subjectsXML = spec.subjects.map { "<dc:subject>\($0)</dc:subject>" }.joined(separator: "\n    ")
        let opfXML = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(spec.title)</dc:title>
            <dc:creator>\(spec.creator)</dc:creator>
            <dc:language>en</dc:language>
            \(subjectsXML)
            <dc:description>\(spec.description)</dc:description>
          </metadata>
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """.utf8)
        try archive.addEntry(with: "content.opf", type: .file, uncompressedSize: UInt32(opfXML.count), compressionMethod: .none) { position, size in
            opfXML.subdata(in: position..<(position + size))
        }

        let chapterXML = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(spec.title)</title></head>
        <body>
          \(spec.bodyHTML)
        </body>
        </html>
        """.utf8)
        try archive.addEntry(with: "chapter1.xhtml", type: .file, uncompressedSize: UInt32(chapterXML.count), compressionMethod: .none) { position, size in
            chapterXML.subdata(in: position..<(position + size))
        }
    }
}
