import Foundation

/// Constructs EPUB 3.0 compliant XML and XHTML5 assets matching the `epub-otwarchive` specification.
enum AO3EPUB3Builder {

    struct ChapterItem: Sendable, Equatable {
        let id: String
        let title: String
        let htmlBody: String
        let chapterNotes: String?

        init(id: String, title: String, htmlBody: String, chapterNotes: String? = nil) {
            self.id = id
            self.title = title
            self.htmlBody = htmlBody
            self.chapterNotes = chapterNotes
        }
    }

    // MARK: - Container XML

    static func containerXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
    }

    // MARK: - Package OPF

    struct PackageOPFOptions: Sendable {
        var title: String
        var workID: String?
        var authors: [AO3AuthorEntry]
        var metadata: AO3MetadataRecord?
        var language: String
        var chapters: [ChapterItem]
        var hasPreface: Bool
        var hasAfterword: Bool
        var additionalManifestItems: [(id: String, href: String, mediaType: String, properties: String?)]

        init(
            title: String,
            workID: String? = nil,
            authors: [AO3AuthorEntry] = [],
            metadata: AO3MetadataRecord? = nil,
            language: String = "en",
            chapters: [ChapterItem] = [],
            hasPreface: Bool = false,
            hasAfterword: Bool = false,
            additionalManifestItems: [(id: String, href: String, mediaType: String, properties: String?)] = []
        ) {
            self.title = title
            self.workID = workID
            self.authors = authors
            self.metadata = metadata
            self.language = language
            self.chapters = chapters
            self.hasPreface = hasPreface
            self.hasAfterword = hasAfterword
            self.additionalManifestItems = additionalManifestItems
        }
    }

    static func buildPackageOPF(options: PackageOPFOptions) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: options.language)
        let identifierURL = options.workID.map { "https://archiveofourown.org/works/\($0)" }
            ?? "urn:uuid:\(UUID().uuidString)"

        let publishedDate = options.metadata?.publishedDate ?? String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let modifiedTimestamp = ISO8601DateFormatter().string(from: Date())

        var creatorTags: [String] = []
        if options.authors.isEmpty {
            creatorTags.append("""
                    <dc:creator id="pseud_0">Anonymous</dc:creator>
                    <meta refines="#pseud_0" property="role" scheme="marc:relators">aut</meta>
            """)
        } else {
            for (idx, author) in options.authors.enumerated() {
                let pseudID = "pseud_\(idx)"
                let displayName = author.pseud ?? author.username
                creatorTags.append("""
                        <dc:creator id="\(pseudID)">\(escapeXML(displayName))</dc:creator>
                        <meta refines="#\(pseudID)" property="file-as">\(escapeXML(author.username))</meta>
                        <meta refines="#\(pseudID)" property="role" scheme="marc:relators">aut</meta>
                """)
            }
        }

        var subjectTags: [String] = []
        if let rating = options.metadata?.rating, !rating.isEmpty {
            subjectTags.append("<dc:subject>Rating -- \(escapeXML(rating))</dc:subject>")
        }
        for warning in options.metadata?.warnings ?? [] {
            subjectTags.append("<dc:subject>Archive Warning -- \(escapeXML(warning))</dc:subject>")
        }
        for fandom in options.metadata?.fandoms ?? [] {
            subjectTags.append("<dc:subject>Fandom -- \(escapeXML(fandom))</dc:subject>")
        }
        for rel in options.metadata?.relationships ?? [] {
            subjectTags.append("<dc:subject>Relationship -- \(escapeXML(rel))</dc:subject>")
        }
        for char in options.metadata?.characters ?? [] {
            subjectTags.append("<dc:subject>Character -- \(escapeXML(char))</dc:subject>")
        }
        for tag in options.metadata?.additionalTags ?? [] {
            subjectTags.append("<dc:subject>Additional Tags -- \(escapeXML(tag))</dc:subject>")
        }

        var manifestItems: [String] = [
            "<item id=\"toc\" href=\"toc.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "<item id=\"style\" href=\"stylesheet.css\" media-type=\"text/css\"/>",
            "<item id=\"imprint\" href=\"imprint.xhtml\" media-type=\"application/xhtml+xml\"/>"
        ]

        if options.hasPreface {
            manifestItems.append("<item id=\"preface\" href=\"preface.xhtml\" media-type=\"application/xhtml+xml\"/>")
        }

        for chapter in options.chapters {
            manifestItems.append("<item id=\"\(chapter.id)\" href=\"\(chapter.id).xhtml\" media-type=\"application/xhtml+xml\"/>")
        }

        if options.hasAfterword {
            manifestItems.append("<item id=\"afterword\" href=\"afterword.xhtml\" media-type=\"application/xhtml+xml\"/>")
        }

        for item in options.additionalManifestItems {
            let propAttr = item.properties.map { " properties=\"\($0)\"" } ?? ""
            manifestItems.append("<item id=\"\(item.id)\" href=\"\(item.href)\" media-type=\"\(item.mediaType)\"\(propAttr)/>")
        }

        var spineItems: [String] = [
            "<itemref idref=\"imprint\"/>"
        ]
        if options.hasPreface {
            spineItems.append("<itemref idref=\"preface\"/>")
        }
        for chapter in options.chapters {
            spineItems.append("<itemref idref=\"\(chapter.id)\"/>")
        }
        if options.hasAfterword {
            spineItems.append("<itemref idref=\"afterword\"/>")
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="url">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:identifier id="url">\(identifierURL)</dc:identifier>
                <dc:title id="title">\(escapeXML(options.title))</dc:title>
                <dc:language>\(bcp47)</dc:language>
                <dc:publisher id="pub">Archive of Our Own</dc:publisher>
                <link refines="#pub" rel="record" href="https://archiveofourown.org/"/>
                <dc:date>\(publishedDate)</dc:date>
                <meta property="dcterms:modified">\(modifiedTimestamp)</meta>
        \(creatorTags.joined(separator: "\n"))
        \(subjectTags.map { "        \($0)" }.joined(separator: "\n"))
            </metadata>
            <manifest>
        \(manifestItems.map { "        \($0)" }.joined(separator: "\n"))
            </manifest>
            <spine>
        \(spineItems.map { "        \($0)" }.joined(separator: "\n"))
            </spine>
        </package>
        """
    }

    // MARK: - Hierarchical TOC

    static func buildTOC(
        title: String,
        chapters: [ChapterItem],
        language: String,
        hasPreface: Bool = false,
        hasAfterword: Bool = false
    ) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)

        var chapterListItems: [String] = []
        for chapter in chapters {
            chapterListItems.append("""
                            <li><a href="\(chapter.id).xhtml">\(escapeXML(chapter.title))</a></li>
            """)
        }

        var topLevelListItems: [String] = [
            "            <li><a href=\"imprint.xhtml\">Imprint</a></li>"
        ]

        if hasPreface {
            topLevelListItems.append("            <li><a href=\"preface.xhtml\">Preface</a></li>")
        }

        topLevelListItems.append("""
                    <li>
                        <span>\(escapeXML(title))</span>
                        <ol>
        \(chapterListItems.joined(separator: "\n"))
                        </ol>
                    </li>
        """)

        if hasAfterword {
            topLevelListItems.append("            <li><a href=\"afterword.xhtml\">Afterword</a></li>")
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>Table of Contents</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body>
            <nav id="toc" epub:type="toc">
                <h1>Table of Contents</h1>
                <ol>
        \(topLevelListItems.joined(separator: "\n"))
                </ol>
            </nav>
        </body>
        </html>
        """
    }

    // MARK: - Imprint Page

    static func buildImprint(
        title: String,
        authors: [AO3AuthorEntry],
        metadata: AO3MetadataRecord?,
        language: String
    ) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)
        let authorNames = authors.isEmpty ? "Anonymous" : authors.map { $0.pseud ?? $0.username }.joined(separator: ", ")

        var metaRows: [String] = []

        if let rating = metadata?.rating, !rating.isEmpty {
            metaRows.append("<dt>Rating:</dt><dd>\(escapeXML(rating))</dd>")
        }
        if let warnings = metadata?.warnings, !warnings.isEmpty {
            metaRows.append("<dt>Archive Warning:</dt><dd>\(escapeXML(warnings.joined(separator: ", ")))</dd>")
        }
        if let fandoms = metadata?.fandoms, !fandoms.isEmpty {
            metaRows.append("<dt>Fandom:</dt><dd>\(escapeXML(fandoms.joined(separator: ", ")))</dd>")
        }
        if let rels = metadata?.relationships, !rels.isEmpty {
            metaRows.append("<dt>Relationship:</dt><dd>\(escapeXML(rels.joined(separator: ", ")))</dd>")
        }
        if let chars = metadata?.characters, !chars.isEmpty {
            metaRows.append("<dt>Characters:</dt><dd>\(escapeXML(chars.joined(separator: ", ")))</dd>")
        }
        if let tags = metadata?.additionalTags, !tags.isEmpty {
            metaRows.append("<dt>Additional Tags:</dt><dd>\(escapeXML(tags.joined(separator: ", ")))</dd>")
        }
        if let series = metadata?.series, !series.isEmpty {
            let seriesStr = series.map { "Part \($0.index) of \($0.name)" }.joined(separator: "; ")
            metaRows.append("<dt>Series:</dt><dd>\(escapeXML(seriesStr))</dd>")
        }

        var stats: [String] = []
        if let published = metadata?.publishedDate {
            stats.append("Published: \(published)")
        }
        if let updated = metadata?.updatedDate {
            stats.append("Updated: \(updated)")
        }
        if let words = metadata?.wordCount {
            stats.append("Words: \(words)")
        }
        if let curr = metadata?.chapterCurrent {
            let total = metadata?.chapterTotal.map { "\($0)" } ?? "?"
            stats.append("Chapters: \(curr)/\(total)")
        }
        if !stats.isEmpty {
            metaRows.append("<dt>Stats:</dt><dd>\(escapeXML(stats.joined(separator: " • ")))</dd>")
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>\(escapeXML(title))</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body epub:type="frontmatter">
            <section class="imprint" epub:type="imprint">
                <header>
                    <h1 class="title">\(escapeXML(title))</h1>
                    <div class="byline">by \(escapeXML(authorNames))</div>
                </header>
                <dl class="tags">
                    \(metaRows.joined(separator: "\n            "))
                </dl>
            </section>
        </body>
        </html>
        """
    }

    // MARK: - Preface & Afterword

    static func buildPreface(
        notes: String,
        language: String
    ) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>Preface</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body epub:type="frontmatter">
            <section class="preface" epub:type="preface">
                <h2>Preface</h2>
                <div class="notes">
                    \(notes)
                </div>
            </section>
        </body>
        </html>
        """
    }

    static func buildChapter(
        chapter: ChapterItem,
        language: String
    ) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)
        var notesHTML = ""
        if let notes = chapter.chapterNotes, !notes.isEmpty {
            notesHTML = """
            <div class="chapter-notes" epub:type="epigraph">
                <h3>Chapter Notes</h3>
                \(notes)
            </div>
            """
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>\(escapeXML(chapter.title))</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body epub:type="bodymatter">
            <section class="chapter" epub:type="chapter">
                <header class="chapter-header">
                    <h2>\(escapeXML(chapter.title))</h2>
                </header>
                \(notesHTML)
                <main class="chapter-body" epub:type="bodymatter">
                    \(chapter.htmlBody)
                </main>
            </section>
        </body>
        </html>
        """
    }

    static func buildAfterword(
        notes: String,
        language: String
    ) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>Afterword</title>
            <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
        </head>
        <body epub:type="backmatter">
            <section class="afterword" epub:type="afterword">
                <h2>Afterword</h2>
                <div class="notes">
                    \(notes)
                </div>
            </section>
        </body>
        </html>
        """
    }

    // MARK: - Stylesheet

    static func ao3Stylesheet() -> String {
        """
        @charset "utf-8";
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Georgia", serif;
            line-height: 1.6;
            margin: 1em;
            padding: 0;
            color: #111;
        }
        h1, h2, h3, h4, h5, h6 {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-weight: 600;
            line-height: 1.25;
            margin-top: 1.5em;
            margin-bottom: 0.5em;
        }
        h1.title {
            font-size: 2em;
            margin-bottom: 0.2em;
            text-align: center;
        }
        .byline {
            font-size: 1.2em;
            font-style: italic;
            text-align: center;
            margin-bottom: 2em;
            color: #555;
        }
        dl.tags {
            display: grid;
            grid-template-columns: auto 1fr;
            gap: 0.4em 1em;
            font-size: 0.9em;
            border-top: 1px solid #ccc;
            border-bottom: 1px solid #ccc;
            padding: 1em 0;
            margin: 1.5em 0;
        }
        dl.tags dt {
            font-weight: bold;
            color: #444;
        }
        dl.tags dd {
            margin: 0;
        }
        .chapter-header {
            margin-bottom: 2em;
            text-align: center;
        }
        .chapter-notes {
            background-color: #f8f8f8;
            border-left: 3px solid #990000;
            padding: 0.8em 1.2em;
            margin: 1.5em 0;
            font-size: 0.95em;
        }
        blockquote {
            margin: 1em 2em;
            padding-left: 1em;
            border-left: 2px solid #ddd;
            font-style: italic;
        }
        p {
            margin-top: 0;
            margin-bottom: 1em;
            text-align: justify;
        }
        nav#toc ol {
            list-style-type: none;
            padding-left: 1em;
        }
        nav#toc li {
            margin: 0.4em 0;
        }
        """
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
