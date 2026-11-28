import Foundation
import JavaScriptCore
import Testing
@testable import Ambrosia

@Suite("Annotation Nectar Parity & Engine Tests")
struct AnnotationParityTests {

    @Test("Legacy Annotation JSON decodes cleanly with default parity fields")
    func testLegacyAnnotationDecoding() throws {
        let legacyJSON = """
        {
            "spineIndex": 2,
            "startChar": 10,
            "endChar": 25,
            "selectedText": "hello world",
            "colorHex": "#0A84FF"
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded.spineIndex == 2)
        #expect(decoded.colorKey == .blue)
        #expect(decoded.spineHref == "")
        #expect(decoded.quotePrefix == "")
        #expect(decoded.quoteSuffix == "")
        #expect(decoded.hasHighlight == true)
        #expect(decoded.needsReanchor == false)
        #expect(decoded.originalText == nil)
    }

    @Test("AmbrosiaMetaDB FTS5 search, reanchor, orphan, and text-edit updates")
    func testMetaDBAnnotationsFTSAndLifecycle() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-ann-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metaDB = try AmbrosiaMetaDB(libraryURL: tempDir)
        let ann = Annotation(
            spineIndex: 1,
            spineHref: "OEBPS/ch1.xhtml",
            startChar: 100,
            endChar: 112,
            selectedText: "stellar drift",
            quotePrefix: "Before the ",
            quoteSuffix: " began.",
            chapterTitle: "Chapter 1",
            note: "Great metaphor",
            colorKey: .purple,
            colorHex: "#BF5AF2"
        )
        try await metaDB.insertAnnotation(ann, calibreID: 42)

        let searchHits = try await metaDB.searchAnnotations(query: "metaphor")
        #expect(searchHits.count == 1)
        #expect(searchHits.first?.annotation.id == ann.id)

        try await metaDB.reanchorAnnotation(
            id: ann.id,
            update: .init(
                spineIndex: 2,
                spineHref: "OEBPS/ch1.xhtml",
                startChar: 150,
                endChar: 162,
                quotePrefix: "Updated prefix ",
                quoteSuffix: " updated suffix",
                chapterTitle: "Chapter 1"
            )
        )
        let reloaded = try await metaDB.annotations(for: 42)
        #expect(reloaded.first?.spineIndex == 2)
        #expect(reloaded.first?.startChar == 150)

        try await metaDB.updateAnnotationDetails(
            id: ann.id,
            update: .init(
                note: "Edited note",
                colorKey: .green,
                colorHex: "#30D158",
                hasHighlight: false,
                originalText: "stellar drift",
                replacementText: "cosmic drift"
            )
        )
        let editHits = try await metaDB.searchAnnotations(query: "cosmic", filterType: .textEdits)
        #expect(editHits.count == 1)
        #expect(editHits.first?.annotation.hasHighlight == false)

        try await metaDB.markAnnotationOrphaned(id: ann.id)
        let orphanHits = try await metaDB.searchAnnotations(query: "", filterType: .orphaned)
        #expect(orphanHits.count == 1)
    }

    @Test("JS anchor resolver disambiguates ranged quotes and point-bookmark seams")
    func testJSAnchorResolution() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var window = this;")
        context.evaluateScript(AnnotationEngineJS.script)

        let fullText = "First time she said hello there. Second time she said hello there quietly."
        let secondIdx = try #require(fullText.range(of: "hello there quietly")?.lowerBound)
        let secondOffset = fullText.distance(from: fullText.startIndex, to: secondIdx)

        let checkScript = """
        (function() {
            var txt = \(try String(data: JSONEncoder().encode(fullText), encoding: .utf8) ?? "\"\"");
            var ranged = window.ambrosiaAnnotationEngine.resolveAnnotationAnchor(txt, {
                startChar: 0,
                endChar: 11,
                selectedText: "hello there",
                quotePrefix: "Second time she said ",
                quoteSuffix: " quietly.",
                needsReanchor: true
            });
            var point = window.ambrosiaAnnotationEngine.resolveAnnotationAnchor(txt, {
                startChar: 0,
                endChar: 0,
                selectedText: "",
                quotePrefix: "Second time she said ",
                quoteSuffix: "hello there quietly.",
                needsReanchor: true
            });
            return JSON.stringify({ ranged: ranged, point: point });
        })();
        """
        let jsonStr = try #require(context.evaluateScript(checkScript)?.toString())
        let data = try #require(jsonStr.data(using: .utf8))
        struct JSAnchor: Decodable {
            let matched: Bool
            let startChar: Int
            let endChar: Int
        }
        struct JSRes: Decodable {
            let ranged: JSAnchor
            let point: JSAnchor
        }
        let decoded = try JSONDecoder().decode(JSRes.self, from: data)
        #expect(decoded.ranged.matched == true)
        #expect(decoded.ranged.startChar == secondOffset)
        #expect(decoded.ranged.endChar == secondOffset + "hello there".count)
        #expect(decoded.point.matched == true)
        #expect(decoded.point.startChar == secondOffset)
        #expect(decoded.point.endChar == secondOffset)
    }

    @Test("SentenceContext reconstructs full containing sentence")
    func testSentenceContext() {
        let res = SentenceContext.extract(
            quotePrefix: "Earlier paragraph. The quick ",
            selectedText: "brown fox",
            quoteSuffix: " jumped over the lazy dog. Next sentence."
        )
        #expect(res.sentence == "The quick brown fox jumped over the lazy dog.")
        if let range = res.highlightRange {
            #expect(String(res.sentence[range]) == "brown fox")
        } else {
            Issue.record("Expected non-nil highlightRange")
        }
    }

    @Test("TextReplacementOffsetShift detects overlaps and shifts downstream descending")
    func testTextReplacementOffsetShift() {
        let a1 = Annotation(spineIndex: 0, startChar: 10, endChar: 20, selectedText: "ten chars!")
        let a2 = Annotation(spineIndex: 0, startChar: 30, endChar: 40, selectedText: "downstream")
        let a3 = Annotation(spineIndex: 0, startChar: 50, endChar: 60, selectedText: "further")

        #expect(TextReplacementOffsetShift.hasOverlap(
            startChar: 15, endChar: 25, spineIndex: 0, annotations: [a1, a2, a3], excludingID: a2.id
        ) == true)

        let shifts = TextReplacementOffsetShift.downstreamShifts(
            editEnd: 20, delta: 5, spineIndex: 0, annotations: [a1, a2, a3], excludingID: a1.id
        )
        #expect(shifts.count == 2)
        #expect(shifts[0].id == a3.id)
        #expect(shifts[0].startChar == 55)
        #expect(shifts[1].id == a2.id)
        #expect(shifts[1].startChar == 35)
    }

    @Test("AnnotationBackupManager flushes and restores lossless JSON snapshots")
    func testBackupAndRestoreRoundTrip() async throws {
        let tempLib = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-backup-lib-\(UUID().uuidString)", isDirectory: true)
        let tempBackupBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-backup-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempBackupBase, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempLib)
            try? FileManager.default.removeItem(at: tempBackupBase)
        }

        let metaDB = try AmbrosiaMetaDB(libraryURL: tempLib)
        let ann = Annotation(
            spineIndex: 0,
            spineHref: "ch1.xhtml",
            startChar: 5,
            endChar: 15,
            selectedText: "saved text",
            quotePrefix: "pre ",
            quoteSuffix: " post",
            note: "Keep safe"
        )
        try await metaDB.insertAnnotation(ann, calibreID: 7)

        try await AnnotationBackupManager.shared.flushNow(
            calibreID: 7,
            libraryURL: tempLib,
            metaDB: metaDB,
            baseDirectory: tempBackupBase
        )

        try await metaDB.deleteAnnotation(id: ann.id, calibreID: 7)
        #expect(try await metaDB.annotations(for: 7).isEmpty)

        let restored = try await AnnotationBackupManager.shared.restoreAllSnapshots(
            libraryURL: tempLib,
            metaDB: metaDB,
            baseDirectory: tempBackupBase
        )
        #expect(restored == 1)
        let after = try await metaDB.annotations(for: 7)
        #expect(after.count == 1)
        #expect(after.first?.note == "Keep safe")
        #expect(after.first?.quotePrefix == "pre ")
    }
}
