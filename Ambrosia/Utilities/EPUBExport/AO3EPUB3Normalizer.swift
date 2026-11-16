import Foundation
import SwiftSoup
import ZIPFoundation

/// Orchestrates the normalization and packaging of raw AO3 / Calibre EPUB 2 files
/// into standards-compliant EPUB 3.0 containers adhering to the `epub-otwarchive` spec.
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
        authors: [String] = []
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

        // Extract text chapters from spine
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
            let bodyHTML = (try? doc.body()?.html()) ?? ""

            // Skip Calibre title page or preface-only spine items if empty or pure metadata card
            let plainText = (try? doc.text()) ?? ""
            if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            // Derive chapter title
            let chapTitle: String = {
                if let heading = try? doc.select("h1, h2, h3").first()?.text(), !heading.isEmpty {
                    return heading
                }
                if parser.spine.count == 1 {
                    return title
                }
                return "Chapter \(chapterIndex)"
            }()

            chapters.append(AO3EPUB3Builder.ChapterItem(
                id: "chapter_\(chapterIndex)",
                title: chapTitle,
                htmlBody: bodyHTML
            ))
            chapterIndex += 1
        }

        if chapters.isEmpty {
            // Fallback for one-shot or non-standard spine
            chapters.append(AO3EPUB3Builder.ChapterItem(
                id: "chapter_1",
                title: title,
                htmlBody: "<p>\(title)</p>"
            ))
        }

        // 3. Prepare EPUB 3 content files
        let containerXMLData = Data(AO3EPUB3Builder.containerXML().utf8)
        let stylesheetData = Data(AO3EPUB3Builder.ao3Stylesheet().utf8)
        let imprintData = Data(AO3EPUB3Builder.buildImprint(
            title: title,
            authors: authorEntries,
            metadata: metadata,
            language: language
        ).utf8)
        let tocData = Data(AO3EPUB3Builder.buildTOC(
            title: title,
            chapters: chapters,
            language: language
        ).utf8)

        var additionalManifestItems: [(id: String, href: String, mediaType: String, properties: String?)] = []
        for (idx, img) in imageEntries.enumerated() {
            let isCover = img.path.lowercased().contains("cover")
            additionalManifestItems.append((
                id: "image_\(idx)",
                href: img.path,
                mediaType: img.mediaType,
                properties: isCover ? "cover-image" : nil
            ))
        }

        let opfData = Data(AO3EPUB3Builder.buildPackageOPF(options: AO3EPUB3Builder.PackageOPFOptions(
            title: title,
            workID: metadata?.workID,
            authors: authorEntries,
            metadata: metadata,
            language: language,
            chapters: chapters,
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

        // Entry 3: OEBPS/package.opf
        try destArchive.addEntry(
            with: "OEBPS/package.opf",
            type: .file,
            uncompressedSize: Int64(opfData.count),
            compressionMethod: .deflate
        ) { position, size in
            opfData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 4: OEBPS/toc.xhtml
        try destArchive.addEntry(
            with: "OEBPS/toc.xhtml",
            type: .file,
            uncompressedSize: Int64(tocData.count),
            compressionMethod: .deflate
        ) { position, size in
            tocData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 5: OEBPS/stylesheet.css
        try destArchive.addEntry(
            with: "OEBPS/stylesheet.css",
            type: .file,
            uncompressedSize: Int64(stylesheetData.count),
            compressionMethod: .deflate
        ) { position, size in
            stylesheetData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 6: OEBPS/imprint.xhtml
        try destArchive.addEntry(
            with: "OEBPS/imprint.xhtml",
            type: .file,
            uncompressedSize: Int64(imprintData.count),
            compressionMethod: .deflate
        ) { position, size in
            imprintData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Entry 7+: OEBPS/chapter_*.xhtml
        for chapter in chapters {
            let chapHTML = AO3EPUB3Builder.buildChapter(chapter: chapter, language: language)
            let chapData = Data(chapHTML.utf8)
            try destArchive.addEntry(
                with: "OEBPS/\(chapter.id).xhtml",
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
                with: "OEBPS/\(img.path)",
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
