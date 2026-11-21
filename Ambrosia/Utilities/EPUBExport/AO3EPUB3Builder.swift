import Foundation

/// Constructs EPUB 3.0 compliant XML and XHTML5 assets matching the `epub-otwarchive` specification.
/// Credit: Based on research and templates by Timothy Cyrus (tcyrus, https://archiveofourown.org/works/89438831)
/// and Nectar's EPUB 3.3 generation engine.
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
                <rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/>
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
        var hasImprint: Bool
        var hasPreface: Bool
        var hasAfterword: Bool
        var primarySeries: (name: String, index: Int)?
        var additionalManifestItems: [(id: String, href: String, mediaType: String, properties: String?)]

        init(
            title: String,
            workID: String? = nil,
            authors: [AO3AuthorEntry] = [],
            metadata: AO3MetadataRecord? = nil,
            language: String = "en",
            chapters: [ChapterItem] = [],
            hasImprint: Bool = true,
            hasPreface: Bool = false,
            hasAfterword: Bool = false,
            primarySeries: (name: String, index: Int)? = nil,
            additionalManifestItems: [(id: String, href: String, mediaType: String, properties: String?)] = []
        ) {
            self.title = title
            self.workID = workID
            self.authors = authors
            self.metadata = metadata
            self.language = language
            self.chapters = chapters
            self.hasImprint = hasImprint
            self.hasPreface = hasPreface
            self.hasAfterword = hasAfterword
            self.primarySeries = primarySeries
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
            subjectTags.append("<dc:subject>\(escapeXML(rating))</dc:subject>")
        }
        for warning in options.metadata?.warnings ?? [] {
            subjectTags.append("<dc:subject>\(escapeXML(warning))</dc:subject>")
        }
        for fandom in options.metadata?.fandoms ?? [] {
            subjectTags.append("<dc:subject>\(escapeXML(fandom))</dc:subject>")
        }
        for rel in options.metadata?.relationships ?? [] {
            subjectTags.append("<dc:subject>\(escapeXML(rel))</dc:subject>")
        }
        for char in options.metadata?.characters ?? [] {
            subjectTags.append("<dc:subject>\(escapeXML(char))</dc:subject>")
        }
        for tag in options.metadata?.additionalTags ?? [] {
            subjectTags.append("<dc:subject>\(escapeXML(tag))</dc:subject>")
        }

        var seriesTags: [String] = []
        let activeSeries = options.primarySeries ?? options.metadata?.series.first.map { ($0.name, $0.index) }
        if let activeSeries {
            seriesTags.append("<meta name=\"calibre:series\" content=\"\(escapeXML(activeSeries.name))\"/>")
            seriesTags.append("<meta name=\"calibre:series_index\" content=\"\(activeSeries.index)\"/>")
            seriesTags.append("<meta property=\"belongs-to-collection\" id=\"series_01\">\(escapeXML(activeSeries.name))</meta>")
            seriesTags.append("<meta refines=\"#series_01\" property=\"collection-type\">series</meta>")
            seriesTags.append("<meta refines=\"#series_01\" property=\"group-position\">\(activeSeries.index)</meta>")
        }

        var manifestItems: [String] = [
            "<item id=\"toc\" href=\"toc.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
            "<item id=\"style\" href=\"css/stylesheet.css\" media-type=\"text/css\"/>",
            "<item id=\"page_styles\" href=\"css/page_styles.css\" media-type=\"text/css\"/>"
        ]

        if options.hasImprint {
            manifestItems.append("<item id=\"imprint\" href=\"text/imprint.xhtml\" media-type=\"application/xhtml+xml\"/>")
        }

        if options.hasPreface {
            manifestItems.append("<item id=\"preface\" href=\"text/preface.xhtml\" media-type=\"application/xhtml+xml\"/>")
        }

        for chapter in options.chapters {
            manifestItems.append("<item id=\"\(chapter.id)\" href=\"text/\(chapter.id).xhtml\" media-type=\"application/xhtml+xml\"/>")
        }

        if options.hasAfterword {
            manifestItems.append("<item id=\"afterword\" href=\"text/afterword.xhtml\" media-type=\"application/xhtml+xml\"/>")
        }

        for item in options.additionalManifestItems {
            let propAttr = item.properties.map { " properties=\"\($0)\"" } ?? ""
            manifestItems.append("<item id=\"\(item.id)\" href=\"\(item.href)\" media-type=\"\(item.mediaType)\"\(propAttr)/>")
        }

        var spineItems: [String] = []
        if options.hasImprint {
            spineItems.append("<itemref idref=\"imprint\"/>")
        }
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
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:identifier id="pub-id">\(identifierURL)</dc:identifier>
                <dc:title id="title">\(escapeXML(options.title))</dc:title>
                <dc:language>\(bcp47)</dc:language>
                <dc:publisher id="pub">Archive of Our Own</dc:publisher>
                <link refines="#pub" rel="record" href="https://archiveofourown.org/"/>
                <dc:date>\(publishedDate)</dc:date>
                <meta property="dcterms:modified">\(modifiedTimestamp)</meta>
        \(creatorTags.joined(separator: "\n"))
        \(subjectTags.map { "        \($0)" }.joined(separator: "\n"))
        \(seriesTags.map { "        \($0)" }.joined(separator: "\n"))
            </metadata>
            <manifest>
        \(manifestItems.map { "        \($0)" }.joined(separator: "\n"))
            </manifest>
            <spine toc="ncx">
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
        hasImprint: Bool = true,
        hasPreface: Bool = false,
        hasAfterword: Bool = false
    ) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)

        var chapterListItems: [String] = []
        for chapter in chapters {
            chapterListItems.append("""
                            <li><a href="text/\(chapter.id).xhtml">\(escapeXML(chapter.title))</a></li>
            """)
        }

        var topLevelListItems: [String] = []

        if hasImprint {
            topLevelListItems.append("            <li><a href=\"text/imprint.xhtml\">Imprint</a></li>")
        }

        if hasPreface {
            topLevelListItems.append("            <li><a href=\"text/preface.xhtml\">Preface</a></li>")
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
            topLevelListItems.append("            <li><a href=\"text/afterword.xhtml\">Afterword</a></li>")
        }

        let titlePageTarget = hasPreface ? "text/preface.xhtml" : "text/imprint.xhtml"

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>Table of Contents</title>
            <link rel="stylesheet" type="text/css" href="css/stylesheet.css"/>
            <link rel="stylesheet" type="text/css" href="css/page_styles.css"/>
        </head>
        <body epub:type="frontmatter">
            <nav id="toc" epub:type="toc" role="doc-toc">
                <h1>Table of Contents</h1>
                <ol>
        \(topLevelListItems.joined(separator: "\n"))
                </ol>
            </nav>
            <nav id="landmarks" epub:type="landmarks">
                <h2>Landmarks</h2>
                <ol>
                    <li><a href="\(titlePageTarget)" epub:type="frontmatter">Title Page</a></li>
                    <li><a href="text/\(chapters.first?.id ?? "chapter_1").xhtml" epub:type="bodymatter">Start of Content</a></li>
                </ol>
            </nav>
        </body>
        </html>
        """
    }

    // MARK: - NCX Fallback Document

    static func buildNCX(
        title: String,
        chapters: [ChapterItem],
        workID: String?,
        hasImprint: Bool = true,
        hasPreface: Bool = false
    ) -> String {
        let identifierURL = workID.map { "https://archiveofourown.org/works/\($0)" }
            ?? "urn:uuid:\(UUID().uuidString)"
        var navPoints: [String] = []
        var order = 1
        if hasImprint {
            navPoints.append("""
            <navPoint id="np_\(order)" playOrder="\(order)">
              <navLabel><text>Imprint</text></navLabel>
              <content src="text/imprint.xhtml"/>
            </navPoint>
            """)
            order += 1
        }
        if hasPreface {
            navPoints.append("""
            <navPoint id="np_\(order)" playOrder="\(order)">
              <navLabel><text>Preface</text></navLabel>
              <content src="text/preface.xhtml"/>
            </navPoint>
            """)
            order += 1
        }
        for chap in chapters {
            navPoints.append("""
            <navPoint id="np_\(order)" playOrder="\(order)">
              <navLabel><text>\(escapeXML(chap.title))</text></navLabel>
              <content src="text/\(chap.id).xhtml"/>
            </navPoint>
            """)
            order += 1
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(identifierURL)"/>
            <meta name="dtb:depth" content="2"/>
            <meta name="dtb:generator" content="Ambrosia"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle>
            <text>\(escapeXML(title))</text>
          </docTitle>
          <navMap>
        \(navPoints.joined(separator: "\n"))
          </navMap>
        </ncx>
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
            <link rel="stylesheet" type="text/css" href="../css/stylesheet.css"/>
            <link rel="stylesheet" type="text/css" href="../css/page_styles.css"/>
        </head>
        <body epub:type="frontmatter">
            <section class="imprint" id="imprint" epub:type="imprint">
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
        content: String,
        language: String
    ) -> String {
        let bcp47 = AO3LanguageMap.bcp47Tag(for: language)
        let hasHeading = content.localizedCaseInsensitiveContains("<h1") || content.localizedCaseInsensitiveContains("<h2")
        let headingHTML = hasHeading ? "" : "<h2>Preface</h2>\n"
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(bcp47)">
        <head>
            <meta charset="utf-8"/>
            <title>Preface</title>
            <link rel="stylesheet" type="text/css" href="../css/stylesheet.css"/>
            <link rel="stylesheet" type="text/css" href="../css/page_styles.css"/>
        </head>
        <body epub:type="frontmatter">
            <section class="preface" epub:type="preface">
                <div id="workskin" class="userstuff">
                    \(headingHTML)\(content)
                </div>
            </section>
        </body>
        </html>
        """
    }

    static func buildPreface(
        notes: String,
        language: String
    ) -> String {
        buildPreface(content: notes, language: language)
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
            <link rel="stylesheet" type="text/css" href="../css/stylesheet.css"/>
            <link rel="stylesheet" type="text/css" href="../css/page_styles.css"/>
        </head>
        <body epub:type="bodymatter">
            <section class="chapter" epub:type="chapter">
                <header class="chapter-header">
                    <h2>\(escapeXML(chapter.title))</h2>
                </header>
                \(notesHTML)
                <main class="chapter-body" epub:type="bodymatter">
                    <div id="workskin" class="userstuff">
                        \(chapter.htmlBody)
                    </div>
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
            <link rel="stylesheet" type="text/css" href="../css/stylesheet.css"/>
            <link rel="stylesheet" type="text/css" href="../css/page_styles.css"/>
        </head>
        <body epub:type="backmatter">
            <section class="afterword" id="afterword" epub:type="afterword">
                <h2>Afterword</h2>
                <div id="workskin" class="userstuff notes">
                    \(notes)
                </div>
            </section>
        </body>
        </html>
        """
    }

    // MARK: - Stylesheets

    static func pageStylesCSS() -> String {
        """
        @page {
            margin-bottom: 5pt;
            margin-top: 5pt;
        }
        """
    }

    static func ao3Stylesheet() -> String {
        """
        @charset "utf-8";
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Georgia", serif;
            line-height: 1.6;
            margin: 1em;
            padding: 0;
            color: #111;
            text-rendering: optimizeLegibility;
        }
        body > section > header h1,
        body > section > header h2,
        body > section > header h3,
        body > section > header h4,
        body > section > header h5,
        body > section > header h6 {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-weight: 600;
            line-height: 1.25;
            margin-top: 1.5em;
            margin-bottom: 0.5em;
            break-after: avoid;
            page-break-after: avoid;
        }
        body > section > header h1.title,
        body > section > header h1 {
            font-size: 2em;
            margin-bottom: 0.2em;
            text-align: center;
        }
        .byline,
        body > section > header .byline {
            font-size: 1.2em;
            font-style: italic;
            text-align: center;
            margin-bottom: 2em;
            color: #555;
        }
        p.message,
        body > section > p.message {
            text-align: center;
            margin: 1em 0;
        }
        dl.tags,
        body > section#imprint > dl.tags,
        body > section.imprint > dl.tags,
        body > section.preface dl.tags {
            display: grid;
            grid-template-columns: auto 1fr;
            gap: 0.4em 1em;
            font-size: 0.9em;
            border: 1px solid #ccc;
            padding: 1em;
            margin: 1.5em 0;
        }
        dl.tags dt,
        body > section#imprint > dl.tags dt,
        body > section.imprint > dl.tags dt,
        body > section.preface dl.tags dt {
            font-weight: bold;
            color: #444;
        }
        dl.tags dd,
        body > section#imprint > dl.tags dd,
        body > section.imprint > dl.tags dd,
        body > section.preface dl.tags dd {
            margin: 0;
        }
        dl.tags dl.stats,
        body > section#imprint > dl.tags dl.stats,
        body > section.imprint > dl.tags dl.stats,
        body > section.preface dl.tags dl.stats {
            margin-top: 0;
            margin-bottom: 0;
        }
        body > section.chapter > header.chapter-header {
            margin-bottom: 2em;
            text-align: center;
        }
        body > section.chapter > .chapter-notes {
            background-color: #f8f8f8;
            border-left: 3px solid #990000;
            padding: 0.8em 1.2em;
            margin: 1.5em 0;
            font-size: 0.95em;
        }
        body > section.chapter > main.chapter-body > div#workskin.userstuff {
            padding: 0;
        }
        div.userstuff p {
            margin-top: 0;
            margin-bottom: 1em;
            text-align: justify;
        }
        div.userstuff blockquote {
            margin: 1em 2em;
            padding-left: 1em;
            border-left: 2px solid #ddd;
            font-style: italic;
        }
        nav#toc ol {
            list-style-type: none;
            padding-left: 1em;
        }
        nav#toc li {
            margin: 0.4em 0;
        }
        @media (prefers-color-scheme: dark) {
            body {
                background-color: #121212;
                color: #e4e4e7;
            }
            .byline,
            body > section > header .byline {
                color: #a1a1aa;
            }
            dl.tags,
            body > section#imprint > dl.tags,
            body > section.imprint > dl.tags,
            body > section.preface dl.tags {
                border-color: #444;
            }
            dl.tags dt,
            body > section#imprint > dl.tags dt,
            body > section.imprint > dl.tags dt,
            body > section.preface dl.tags dt {
                color: #d4d4d8;
            }
            body > section.chapter > .chapter-notes {
                background-color: #1e1e1e;
                color: #e4e4e7;
                border-left-color: #cc3333;
            }
            div.userstuff blockquote {
                border-left-color: #555;
                color: #d1d5db;
            }
            hr {
                background: #444;
            }
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
