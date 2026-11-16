import Foundation
import SwiftSoup
import ZIPFoundation

/// Policy controlling how incomplete fanfiction series (missing sequential works) are compiled.
enum IncompleteSeriesPolicy: String, CaseIterable, Sendable {
    /// Omit from omnibus compilation until all sequential parts are present.
    case skip
    /// Warn the user and export a link manifest to download missing parts first.
    case warnWithManifest
    /// Compile available parts, inserting a standardized missing-work placeholder page.
    case includeWithPlaceholders
}

/// Policy controlling how ongoing/unfinished WIP series are compiled.
enum UnfinishedSeriesPolicy: String, CaseIterable, Sendable {
    /// Clearly mark omnibus frontmatter and metadata with [WIP] status and compilation date.
    case tagAsWIP
    /// Exclude ongoing series from omnibus generation until marked complete by the author.
    case requireComplete
}

/// Bundles multi-work fanfiction series into a unified, standards-compliant EPUB 3.0 omnibus.
enum AO3OmnibusBuilder {

    enum OmnibusError: LocalizedError {
        case seriesIncomplete(missingIndices: [Int])
        case manifestRequired(manifest: String)
        case seriesUnfinished
        case emptySeries
        case buildFailed(String)

        var errorDescription: String? {
            switch self {
            case .seriesIncomplete(let indices):
                return "The series is missing parts: \(indices.map(String.init).joined(separator: ", "))."
            case .manifestRequired:
                return "Manifest export required before compilation."
            case .seriesUnfinished:
                return "The series is still in progress (Work in Progress)."
            case .emptySeries:
                return "The series does not contain any books."
            case .buildFailed(let msg):
                return "Omnibus compilation failed: \(msg)"
            }
        }
    }

    struct OmnibusPart: Sendable {
        let partIndex: Int
        let title: String
        let isPlaceholder: Bool
        let chapters: [AO3EPUB3Builder.ChapterItem]
    }

    /// Compiles a series into a single EPUB 3 omnibus container.
    static func buildOmnibus(
        series: SeriesGroup,
        libraryRoot: URL,
        metadataByID: [Int: AO3MetadataRecord],
        incompletePolicy: IncompleteSeriesPolicy = .includeWithPlaceholders,
        unfinishedPolicy: UnfinishedSeriesPolicy = .tagAsWIP,
        destinationEPUB: URL
    ) throws {
        guard !series.works.isEmpty else {
            throw OmnibusError.emptySeries
        }

        let report = SeriesGapAnalyzer.analyze(series: series, metadataByID: metadataByID)

        // 1. Evaluate incomplete series policy
        if !report.missingIndices.isEmpty {
            switch incompletePolicy {
            case .skip:
                throw OmnibusError.seriesIncomplete(missingIndices: report.missingIndices)
            case .warnWithManifest:
                let manifest = SeriesGapManifestBuilder.generateTextManifest(report: report)
                throw OmnibusError.manifestRequired(manifest: manifest)
            case .includeWithPlaceholders:
                break // Proceed with placeholders
            }
        }

        // 2. Evaluate unfinished series policy
        let isWIP = !series.isComplete
        if isWIP && unfinishedPolicy == .requireComplete {
            throw OmnibusError.seriesUnfinished
        }

        let omnibusTitle = series.seriesName + (isWIP ? " [WIP]" : "") + " (Omnibus)"
        let language = metadataByID[series.works[0].id]?.language ?? "en"
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)

        // 3. Extract chapters and assets across all available books
        var parts: [OmnibusPart] = []
        var allImageEntries: [(path: String, data: Data, mediaType: String)] = []

        let imageExtensions: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "svg": "image/svg+xml",
            "webp": "image/webp"
        ]

        // Map works by part index
        var worksByPart: [Int: CalibreBook] = [:]
        for work in series.works {
            if let meta = metadataByID[work.id] {
                for seriesEntry in meta.series where seriesEntry.name.caseInsensitiveCompare(series.seriesName) == .orderedSame {
                    worksByPart[seriesEntry.index] = work
                }
            }
        }
        // Fallback: assign remaining unmapped works sequentially
        var unassignedWorks = series.works.filter { work in
            !worksByPart.values.contains { $0.id == work.id }
        }
        for part in 1...report.totalKnownParts where worksByPart[part] == nil && !unassignedWorks.isEmpty {
            worksByPart[part] = unassignedWorks.removeFirst()
        }

        for partIndex in 1...report.totalKnownParts {
            if let book = worksByPart[partIndex], let epubURL = book.epubURL(libraryRoot: libraryRoot) {
                // Parse member book
                var parser = EPUBParser(epubURL: epubURL)
                try? parser.parse()

                guard let archive = try? Archive(url: epubURL, accessMode: .read, pathEncoding: nil) else { continue }

                // Extract images
                for entry in archive {
                    let ext = (entry.path as NSString).pathExtension.lowercased()
                    if let mediaType = imageExtensions[ext] {
                        var imgData = Data()
                        _ = try? archive.extract(entry) { chunk in
                            imgData.append(chunk)
                        }
                        if !imgData.isEmpty {
                            let filename = (entry.path as NSString).lastPathComponent
                            allImageEntries.append(("images/part\(partIndex)_\(filename)", imgData, mediaType))
                        }
                    }
                }

                // Extract chapters
                var chapters: [AO3EPUB3Builder.ChapterItem] = []
                var chapterNum = 1

                for spineItem in parser.spine {
                    guard let entry = archive[spineItem.href] else { continue }
                    var entryData = Data()
                    _ = try? archive.extract(entry) { chunk in
                        entryData.append(chunk)
                    }
                    guard !entryData.isEmpty else { continue }

                    let rawHTML = String(data: entryData, encoding: .utf8)
                        ?? String(data: entryData, encoding: .isoLatin1)
                        ?? ""
                    let doc = try SwiftSoup.parse(rawHTML)
                    let bodyHTML = (try? doc.body()?.html()) ?? ""
                    let text = (try? doc.text()) ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                    let chapTitle: String = {
                        if let heading = try? doc.select("h1, h2, h3").first()?.text(), !heading.isEmpty {
                            return heading
                        }
                        if parser.spine.count == 1 {
                            return book.displayTitle
                        }
                        return "Chapter \(chapterNum)"
                    }()

                    chapters.append(AO3EPUB3Builder.ChapterItem(
                        id: "part\(partIndex)_chap\(chapterNum)",
                        title: chapTitle,
                        htmlBody: bodyHTML
                    ))
                    chapterNum += 1
                }

                if chapters.isEmpty {
                    chapters.append(AO3EPUB3Builder.ChapterItem(
                        id: "part\(partIndex)_chap1",
                        title: book.displayTitle,
                        htmlBody: "<p>\(book.displayTitle)</p>"
                    ))
                }

                parts.append(OmnibusPart(
                    partIndex: partIndex,
                    title: book.displayTitle,
                    isPlaceholder: false,
                    chapters: chapters
                ))
            } else if report.missingIndices.contains(partIndex) {
                // Insert placeholder part
                let placeholderHTML = """
                <section class="series-placeholder-part" epub:type="part">
                    <h2>Part \(partIndex): Missing Work</h2>
                    <div class="placeholder-notice">
                        <p><em>This work is missing from your local library compilation.</em></p>
                        \(report.ao3SeriesID.map { "<p>Canonical Series URL: <a href=\"https://archiveofourown.org/series/\($0)\">AO3 Series Page</a></p>" } ?? "")
                    </div>
                </section>
                """
                parts.append(OmnibusPart(
                    partIndex: partIndex,
                    title: "Part \(partIndex): Missing Work",
                    isPlaceholder: true,
                    chapters: [
                        AO3EPUB3Builder.ChapterItem(
                            id: "part\(partIndex)_placeholder",
                            title: "Part \(partIndex) (Missing)",
                            htmlBody: placeholderHTML
                        )
                    ]
                ))
            }
        }

        // 4. Build Omnibus TOC
        var tocListItems: [String] = [
            "            <li><a href=\"imprint.xhtml\">Series Imprint &amp; Notes</a></li>"
        ]

        for part in parts {
            var partChapterItems: [String] = []
            for chap in part.chapters {
                partChapterItems.append("""
                                <li><a href="\(chap.id).xhtml">\(escapeXML(chap.title))</a></li>
                """)
            }

            tocListItems.append("""
                        <li>
                            <span>Part \(part.partIndex): \(escapeXML(part.title))</span>
                            <ol>
            \(partChapterItems.joined(separator: "\n"))
                            </ol>
                        </li>
            """)
        }

        tocListItems.append("            <li><a href=\"afterword.xhtml\">Series Afterword &amp; Statistics</a></li>")

        let tocContent = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>\(escapeXML(omnibusTitle))</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body>
            <nav id="toc" epub:type="toc">
                <h1>\(escapeXML(omnibusTitle))</h1>
                <ol>
        \(tocListItems.joined(separator: "\n"))
                </ol>
            </nav>
        </body>
        </html>
        """

        // 5. Build Omnibus Imprint
        let authorNames = series.allAuthors.isEmpty ? "Unknown" : series.allAuthors.joined(separator: ", ")
        let imprintContent = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>\(escapeXML(omnibusTitle))</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body epub:type="frontmatter">
            <section class="imprint" epub:type="imprint">
                <header>
                    <h1 class="title">\(escapeXML(omnibusTitle))</h1>
                    <div class="byline">by \(escapeXML(authorNames))</div>
                </header>
                <dl class="tags">
                    <dt>Series:</dt><dd>\(escapeXML(series.seriesName))</dd>
                    <dt>Works:</dt><dd>\(parts.count) parts (\(report.presentIndices.count) present, \(report.missingIndices.count) missing)</dd>
                    <dt>Word Count:</dt><dd>\(formatNumber(series.totalWordCount)) words</dd>
                    \(series.allFandoms.isEmpty ? "" : "<dt>Fandoms:</dt><dd>\(escapeXML(series.allFandoms.joined(separator: ", ")))</dd>")
                    \(series.allRelationships.isEmpty ? "" : "<dt>Relationships:</dt><dd>\(escapeXML(series.allRelationships.joined(separator: ", ")))</dd>")
                    \(series.allCharacters.isEmpty ? "" : "<dt>Characters:</dt><dd>\(escapeXML(series.allCharacters.joined(separator: ", ")))</dd>")
                    \(isWIP ? "<dt>Status:</dt><dd><strong>Work in Progress [WIP]</strong></dd>" : "<dt>Status:</dt><dd>Complete</dd>")
                </dl>
            </section>
        </body>
        </html>
        """

        // 6. Build Omnibus Afterword
        let afterwordContent = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>Series Afterword</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body epub:type="backmatter">
            <section class="afterword" epub:type="afterword">
                <h2>Series Afterword &amp; Statistics</h2>
                <p>This omnibus edition was compiled by Ambrosia on \(ISO8601DateFormatter().string(from: Date()).prefix(10)).</p>
                <ul>
                    <li>Total Works Compiled: \(parts.count)</li>
                    <li>Total Words: \(formatNumber(series.totalWordCount))</li>
                    \(report.ao3SeriesID.map { "<li>AO3 Series ID: \($0)</li>" } ?? "")
                </ul>
            </section>
        </body>
        </html>
        """

        // 7. Build OPF
        let allChapters = parts.flatMap(\.chapters)
        var additionalManifestItems: [(id: String, href: String, mediaType: String, properties: String?)] = []
        for (idx, img) in allImageEntries.enumerated() {
            additionalManifestItems.append((
                id: "image_\(idx)",
                href: img.path,
                mediaType: img.mediaType,
                properties: nil
            ))
        }

        let authorEntries = series.allAuthors.map {
            AO3AuthorEntry(username: $0, pseud: nil, profileURL: nil, source: .calibre)
        }
        let opfContent = AO3EPUB3Builder.buildPackageOPF(options: AO3EPUB3Builder.PackageOPFOptions(
            title: omnibusTitle,
            workID: report.ao3SeriesID,
            authors: authorEntries,
            metadata: nil,
            language: language,
            chapters: allChapters,
            hasPreface: false,
            hasAfterword: true,
            additionalManifestItems: additionalManifestItems
        ))

        // 8. Package with ZIPFoundation
        if FileManager.default.fileExists(atPath: destinationEPUB.path) {
            try? FileManager.default.removeItem(at: destinationEPUB)
        }

        guard let destArchive = try? Archive(url: destinationEPUB, accessMode: .create, pathEncoding: nil) else {
            throw OmnibusError.buildFailed("Failed to create destination archive.")
        }

        // Mimetype first, uncompressed
        let mimetypeData = Data("application/epub+zip".utf8)
        try destArchive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(mimetypeData.count),
            compressionMethod: .none
        ) { pos, size in
            mimetypeData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        // Container XML
        let containerData = Data(AO3EPUB3Builder.containerXML().utf8)
        try destArchive.addEntry(
            with: "META-INF/container.xml",
            type: .file,
            uncompressedSize: Int64(containerData.count),
            compressionMethod: .deflate
        ) { pos, size in
            containerData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        // OPF
        let opfData = Data(opfContent.utf8)
        try destArchive.addEntry(
            with: "OEBPS/package.opf",
            type: .file,
            uncompressedSize: Int64(opfData.count),
            compressionMethod: .deflate
        ) { pos, size in
            opfData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        // TOC
        let tocData = Data(tocContent.utf8)
        try destArchive.addEntry(
            with: "OEBPS/toc.xhtml",
            type: .file,
            uncompressedSize: Int64(tocData.count),
            compressionMethod: .deflate
        ) { pos, size in
            tocData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        // Stylesheet
        let styleData = Data(AO3EPUB3Builder.ao3Stylesheet().utf8)
        try destArchive.addEntry(
            with: "OEBPS/stylesheet.css",
            type: .file,
            uncompressedSize: Int64(styleData.count),
            compressionMethod: .deflate
        ) { pos, size in
            styleData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        // Imprint
        let imprintData = Data(imprintContent.utf8)
        try destArchive.addEntry(
            with: "OEBPS/imprint.xhtml",
            type: .file,
            uncompressedSize: Int64(imprintData.count),
            compressionMethod: .deflate
        ) { pos, size in
            imprintData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        // Afterword
        let afterwordData = Data(afterwordContent.utf8)
        try destArchive.addEntry(
            with: "OEBPS/afterword.xhtml",
            type: .file,
            uncompressedSize: Int64(afterwordData.count),
            compressionMethod: .deflate
        ) { pos, size in
            afterwordData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        // Chapters
        for chapter in allChapters {
            let chapHTML = AO3EPUB3Builder.buildChapter(chapter: chapter, language: language)
            let chapData = Data(chapHTML.utf8)
            try destArchive.addEntry(
                with: "OEBPS/\(chapter.id).xhtml",
                type: .file,
                uncompressedSize: Int64(chapData.count),
                compressionMethod: .deflate
            ) { pos, size in
                chapData.subdata(in: Int(pos)..<(Int(pos) + size))
            }
        }

        // Images
        for img in allImageEntries {
            try destArchive.addEntry(
                with: "OEBPS/\(img.path)",
                type: .file,
                uncompressedSize: Int64(img.data.count),
                compressionMethod: .deflate
            ) { pos, size in
                img.data.subdata(in: Int(pos)..<(Int(pos) + size))
            }
        }
    }

    private static func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
