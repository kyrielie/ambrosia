import Foundation
import SwiftSoup
import ZIPFoundation

/// Orchestrates the normalization and packaging of raw AO3 / Calibre EPUB 2 files
/// into standards-compliant EPUB 3.0 containers adhering to the `epub-otwarchive` spec.
/// Credit: Based on research and templates by Timothy Cyrus (tcyrus, https://archiveofourown.org/works/89438831)
/// and Nectar's EPUB 3.3 generation engine.
enum AO3EPUB3Normalizer {

    enum NormalizerError: LocalizedError {
        case sourceArchiveUnreadable
        case destinationArchiveCreationFailed
        case missingContent
        case packagingFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceArchiveUnreadable:
                return "Failed to open and read the source EPUB archive."
            case .destinationArchiveCreationFailed:
                return "Could not create the target EPUB 3 archive."
            case .missingContent:
                return "The source EPUB does not contain any readable content chapters."
            case .packagingFailed(let msg):
                return "EPUB 3 packaging failed: \(msg)"
            }
        }
    }

    /// Normalizes a source EPUB into a clean EPUB 3 container at the destination path.
    static func normalize(
        sourceEPUB: URL,
        destinationEPUB: URL,
        metadata: AO3MetadataRecord?,
        bookTitle: String? = nil,
        authors: [String] = [],
        targetSeries: (name: String, index: Int)? = nil
    ) throws {
        guard let sourceArchive = try? Archive(url: sourceEPUB, accessMode: .read, pathEncoding: nil) else {
            throw NormalizerError.sourceArchiveUnreadable
        }

        // 1. Initialize EPUBParser to read spine and structure
        var parser = EPUBParser(epubURL: sourceEPUB)
        try parser.parse()

        let title = metadata.flatMap { record in
            record.storyURL != nil ? bookTitle : nil
        } ?? parser.title.nilIfEmpty ?? bookTitle ?? "Untitled Work"

        let authorEntries: [AO3AuthorEntry] = {
            if let metaAuthors = metadata?.authors, !metaAuthors.isEmpty {
                return metaAuthors
            }
            if !authors.isEmpty {
                return authors.map { AO3AuthorEntry(username: $0, pseud: nil, profileURL: nil, source: .calibre) }
            }
            if !parser.opfCreators.isEmpty {
                return parser.opfCreators.map { AO3AuthorEntry(username: $0, pseud: nil, profileURL: nil, source: .opfCreator) }
            }
            return [AO3AuthorEntry(username: "Anonymous", pseud: nil, profileURL: nil, source: .calibre)]
        }()

        let language = metadata?.language ?? "en"

        // 2. Extract chapters and images from the source archive
        var chapters: [AO3EPUB3Builder.ChapterItem] = []
        var imageEntries: [(path: String, data: Data, mediaType: String)] = []
        var extractedPrefaceHTML: String?

        // Extract images and assets
        let imageExtensions: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "svg": "image/svg+xml",
            "webp": "image/webp"
        ]

        for entry in sourceArchive {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            if let mediaType = imageExtensions[ext] {
                var imgData = Data()
                _ = try? sourceArchive.extract(entry) { chunk in
                    imgData.append(chunk)
                }
                if !imgData.isEmpty {
                    let filename = (entry.path as NSString).lastPathComponent
                    imageEntries.append(("images/\(filename)", imgData, mediaType))
                }
            }
        }

        // Intermediate representation of spine documents for normalization, deduplication, and link rewriting
        struct SpineDocItem {
            let originalHref: String
            let originalFilename: String
            let targetFilename: String
            let isPreface: Bool
            let doc: SwiftSoup.Document
            let chapTitle: String
            let chapterID: String
        }

        var spineDocItems: [SpineDocItem] = []
        var spineToTargetMap: [String: String] = [:]
        var idToTargetMap: [String: String] = [:]
        var foundPreface = false
        var chapterIndex = 1

        for spineItem in parser.spine {
            guard let entry = sourceArchive[spineItem.href] else { continue }
            var entryData = Data()
            _ = try? sourceArchive.extract(entry) { chunk in
                entryData.append(chunk)
            }
            guard !entryData.isEmpty else { continue }

            let rawHTML = String(data: entryData, encoding: .utf8)
                ?? String(data: entryData, encoding: .isoLatin1)
                ?? ""

            let doc = try SwiftSoup.parse(rawHTML)
            _ = doc.outputSettings().syntax(syntax: .xml)

            // Skip Calibre title page or empty spine items
            let plainText = (try? doc.text()) ?? ""
            if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let originalFilename = (spineItem.href as NSString).lastPathComponent
            let isAO3PrefaceCard = (try? doc.select("#preface, dl.tags").first()) != nil

            if isAO3PrefaceCard && !foundPreface && parser.spine.count > 1 {
                foundPreface = true
                let targetFilename = "preface.xhtml"
                spineToTargetMap[originalFilename] = targetFilename
                spineToTargetMap[spineItem.href] = targetFilename

                if let elementsWithId = try? doc.select("[id]") {
                    for el in elementsWithId {
                        if let id = try? el.attr("id"), !id.isEmpty {
                            idToTargetMap[id] = targetFilename
                        }
                    }
                }

                spineDocItems.append(SpineDocItem(
                    originalHref: spineItem.href,
                    originalFilename: originalFilename,
                    targetFilename: targetFilename,
                    isPreface: true,
                    doc: doc,
                    chapTitle: "Preface",
                    chapterID: "preface"
                ))
            } else {
                let targetFilename = "chapter_\(chapterIndex).xhtml"
                let chapterID = "chapter_\(chapterIndex)"
                spineToTargetMap[originalFilename] = targetFilename
                spineToTargetMap[spineItem.href] = targetFilename

                // Derive chapter title
                let headingEl = try? doc.select("h1, h2, h3").first()
                let chapTitle: String = {
                    if let heading = try? headingEl?.text(), !heading.isEmpty {
                        return heading
                    }
                    if parser.spine.count == 1 {
                        return title
                    }
                    return "Chapter \(chapterIndex)"
                }()

                // If the heading had an anchor id, preserve it as an anchor span before removing the heading element
                if let headingID = try? headingEl?.attr("id"), !headingID.isEmpty {
                    _ = try? headingEl?.before("<span id=\"\(headingID)\"></span>")
                }

                // Remove extracted heading from document body so chapter headings are not duplicated
                _ = try? headingEl?.remove()

                if let elementsWithId = try? doc.select("[id]") {
                    for el in elementsWithId {
                        if let id = try? el.attr("id"), !id.isEmpty {
                            idToTargetMap[id] = targetFilename
                        }
                    }
                }

                spineDocItems.append(SpineDocItem(
                    originalHref: spineItem.href,
                    originalFilename: originalFilename,
                    targetFilename: targetFilename,
                    isPreface: false,
                    doc: doc,
                    chapTitle: chapTitle,
                    chapterID: chapterID
                ))
                chapterIndex += 1
            }
        }

        // Rewrite internal cross-references across all extracted documents
        for item in spineDocItems {
            if let links = try? item.doc.select("a[href]") {
                for link in links {
                    guard let href = try? link.attr("href"), !href.isEmpty else { continue }
                    if href.contains("://") || href.hasPrefix("mailto:") || href.hasPrefix("javascript:") {
                        continue
                    }

                    if href.hasPrefix("#") {
                        let fragment = String(href.dropFirst())
                        if let targetFile = idToTargetMap[fragment] {
                            if targetFile != item.targetFilename {
                                _ = try? link.attr("href", "\(targetFile)#\(fragment)")
                            }
                        }
                    } else {
                        let components = href.components(separatedBy: "#")
                        let filePart = (components[0] as NSString).lastPathComponent
                        let fragmentPart = components.count > 1 ? "#\(components[1])" : ""

                        if let targetFile = spineToTargetMap[filePart] {
                            _ = try? link.attr("href", "\(targetFile)\(fragmentPart)")
                        } else if components.count > 1, let targetFile = idToTargetMap[components[1]] {
                            _ = try? link.attr("href", "\(targetFile)#\(components[1])")
                        }
                    }
                }
            }

            if let images = try? item.doc.select("img[src]") {
                for img in images {
                    guard let src = try? img.attr("src"), !src.isEmpty else { continue }
                    if src.contains("://") || src.hasPrefix("data:") { continue }
                    let filename = (src as NSString).lastPathComponent
                    _ = try? img.attr("src", "../images/\(filename)")
                }
            }

            if item.isPreface {
                extractedPrefaceHTML = (try? item.doc.body()?.html()) ?? (try? item.doc.html())
            } else {
                let bodyHTML = (try? item.doc.body()?.html()) ?? ""
                chapters.append(AO3EPUB3Builder.ChapterItem(
                    id: item.chapterID,
                    title: item.chapTitle,
                    htmlBody: bodyHTML
                ))
            }
        }

        if chapters.isEmpty {
            // Fallback for one-shot or non-standard spine
            chapters.append(AO3EPUB3Builder.ChapterItem(
                id: "chapter_1",
                title: title,
                htmlBody: "<p>\(title)</p>"
            ))
        }

        let hasPreface = extractedPrefaceHTML != nil
        let hasImprint = !hasPreface

        // 3. Prepare EPUB 3 content files
        let containerXMLData = Data(AO3EPUB3Builder.containerXML().utf8)
        let stylesheetData = Data(AO3EPUB3Builder.ao3Stylesheet().utf8)
        let pageStylesData = Data(AO3EPUB3Builder.pageStylesCSS().utf8)
        let prefaceData = extractedPrefaceHTML.map {
            Data(AO3EPUB3Builder.buildPreface(content: $0, language: language).utf8)
        }
        let imprintData = hasImprint ? Data(AO3EPUB3Builder.buildImprint(
            title: title,
            authors: authorEntries,
            metadata: metadata,
            language: language
        ).utf8) : nil
        let tocData = Data(AO3EPUB3Builder.buildTOC(
            title: title,
            chapters: chapters,
            language: language,
            hasImprint: hasImprint,
            hasPreface: hasPreface
        ).utf8)
        let ncxData = Data(AO3EPUB3Builder.buildNCX(
            title: title,
            chapters: chapters,
            workID: metadata?.workID,
            hasImprint: hasImprint,
            hasPreface: hasPreface
        ).utf8)

        var additionalManifestItems: [(id: String, href: String, mediaType: String, properties: String?)] = []
        for (idx, img) in imageEntries.enumerated() {
            // Strictly NO COVERS: Never inject synthetic cover properties
            additionalManifestItems.append((
                id: "image_\(idx)",
                href: img.path,
                mediaType: img.mediaType,
                properties: nil
            ))
        }

        let opfData = Data(AO3EPUB3Builder.buildPackageOPF(options: AO3EPUB3Builder.PackageOPFOptions(
            title: title,
            workID: metadata?.workID,
            authors: authorEntries,
            metadata: metadata,
            language: language,
            chapters: chapters,
            hasImprint: hasImprint,
            hasPreface: hasPreface,
            primarySeries: targetSeries ?? metadata?.series.first.map { ($0.name, $0.index) },
            additionalManifestItems: additionalManifestItems
        )).utf8)

        // 4. Construct destination EPUB 3 zip archive
        // Remove existing file at destination if present
        if FileManager.default.fileExists(atPath: destinationEPUB.path) {
            try? FileManager.default.removeItem(at: destinationEPUB)
        }

        guard let destArchive = try? Archive(url: destinationEPUB, accessMode: .create, pathEncoding: nil) else {
            throw NormalizerError.destinationArchiveCreationFailed
        }

        // OCF Rule: mimetype MUST be entry #1, stored uncompressed
        let mimetypeData = Data("application/epub+zip".utf8)
        try destArchive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(mimetypeData.count),
            compressionMethod: .none
        ) { position, size in
            mimetypeData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 2: META-INF/container.xml
        try destArchive.addEntry(
            with: "META-INF/container.xml",
            type: .file,
            uncompressedSize: Int64(containerXMLData.count),
            compressionMethod: .deflate
        ) { position, size in
            containerXMLData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 3: EPUB/content.opf
        try destArchive.addEntry(
            with: "EPUB/content.opf",
            type: .file,
            uncompressedSize: Int64(opfData.count),
            compressionMethod: .deflate
        ) { position, size in
            opfData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 4: EPUB/toc.xhtml
        try destArchive.addEntry(
            with: "EPUB/toc.xhtml",
            type: .file,
            uncompressedSize: Int64(tocData.count),
            compressionMethod: .deflate
        ) { position, size in
            tocData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 5: EPUB/toc.ncx
        try destArchive.addEntry(
            with: "EPUB/toc.ncx",
            type: .file,
            uncompressedSize: Int64(ncxData.count),
            compressionMethod: .deflate
        ) { position, size in
            ncxData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 6: EPUB/css/stylesheet.css
        try destArchive.addEntry(
            with: "EPUB/css/stylesheet.css",
            type: .file,
            uncompressedSize: Int64(stylesheetData.count),
            compressionMethod: .deflate
        ) { position, size in
            stylesheetData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 7: EPUB/css/page_styles.css
        try destArchive.addEntry(
            with: "EPUB/css/page_styles.css",
            type: .file,
            uncompressedSize: Int64(pageStylesData.count),
            compressionMethod: .deflate
        ) { position, size in
            pageStylesData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 8: EPUB/text/preface.xhtml or EPUB/text/imprint.xhtml
        if let prefaceData {
            try destArchive.addEntry(
                with: "EPUB/text/preface.xhtml",
                type: .file,
                uncompressedSize: Int64(prefaceData.count),
                compressionMethod: .deflate
            ) { position, size in
                prefaceData.subdata(in: Int(position)..<(Int(position) + size))
            }
        } else if let imprintData {
            try destArchive.addEntry(
                with: "EPUB/text/imprint.xhtml",
                type: .file,
                uncompressedSize: Int64(imprintData.count),
                compressionMethod: .deflate
            ) { position, size in
                imprintData.subdata(in: Int(position)..<(Int(position) + size))
            }
        }

        // Entry 9+: EPUB/text/chapter_*.xhtml
        for chapter in chapters {
            let chapHTML = AO3EPUB3Builder.buildChapter(chapter: chapter, language: language)
            let chapData = Data(chapHTML.utf8)
            try destArchive.addEntry(
                with: "EPUB/text/\(chapter.id).xhtml",
                type: .file,
                uncompressedSize: Int64(chapData.count),
                compressionMethod: .deflate
            ) { position, size in
                chapData.subdata(in: Int(position)..<(Int(position) + size))
            }
        }

        // Image entries
        for img in imageEntries {
            try destArchive.addEntry(
                with: "EPUB/\(img.path)",
                type: .file,
                uncompressedSize: Int64(img.data.count),
                compressionMethod: .deflate
            ) { position, size in
                img.data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
