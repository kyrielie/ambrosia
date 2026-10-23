import Foundation
import SwiftSoup

// MARK: - EPUBParser rendering (html/mergedHTML/plainText)
//
// Split out of EPUBParser.swift to stay under SwiftLint's file_length limit.
// See EPUBParser.swift for the core type and its shared archive helpers
// (openArchive(), extract(_:from:)) that the methods below call into.
extension EPUBParser {

    // MARK: - html(for:userCSS:)

    /// Returns sanitised HTML for a single spine item, with publisher CSS stripped
    /// and userCSS injected before </head>.
    /// - Parameter globalSpineIndex: The value written into `window.currentSpineIndex`
    ///   (via `sanitise`). Defaults to `item.index` (this work's own local
    ///   index), matching prior single-book behavior exactly. A multi-work
    ///   series read passes the series-wide global index instead (see
    ///   `GlobalSpineRef`), so `window.currentSpineIndex` agrees with the
    ///   globally-unique `data-spine-index` values scroll mode's merged HTML
    ///   already emits — required so JS-side spine resolution (annotation
    ///   capture, link navigation) is consistent between paginated and
    ///   scroll mode. This does not affect `item.index`, which still governs
    ///   this work's own preface/endmatter checks below.
    /// - Parameter removeParagraphIndents: When true, strips leading space/tab
    ///   runs at the start of paragraph-like elements' text. Publisher CSS is
    ///   already stripped unconditionally by `sanitise`, so a CSS-only
    ///   `text-indent: 0` override (as the in-app reader stylesheet used to
    ///   rely on) has nothing left to override here — this handles the case
    ///   CSS never could: books that fake first-line indentation with literal
    ///   whitespace characters in the text itself.
    func html(
        for item: SpineItem,
        userCSS: String,
        globalSpineIndex: Int? = nil,
        removeParagraphIndents: Bool = false
    ) throws -> String {
        let archive = try openArchive()
        guard let entry = archive[item.href],
              let data  = Self.extract(entry, from: archive)
        else { throw EPUBError.missingSpineItem(item.href) }

        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        var html = Self.sanitise(
            raw,
            userCSS: userCSS,
            spineIndex: globalSpineIndex ?? item.index,
            removeParagraphIndents: removeParagraphIndents
        )

        // Match mergedHTML's per-item behaviour: strip the redundant "Preface"
        // heading on the first spine item (unconditional, not gated on
        // ao3Record — the heading is in the raw EPUB regardless of whether
        // Ambrosia extracted structured AO3 metadata for it).
        if item.index == 0 {
            html = Self.stripPrefaceHeading(html)
        }

        // Append AO3 endmatter on the last spine item, when available.
        if item.index == spine.count - 1,
           let record = ao3Record, let workURL = record.storyURL {
            let endmatter = Self.buildAO3Endmatter(record: record, workURL: workURL)
            if let bodyClose = html.range(of: "</body>", options: .caseInsensitive) {
                html.insert(contentsOf: endmatter, at: bodyClose.lowerBound)
            } else {
                html += endmatter
            }
        }

        return html
    }

    // MARK: - mergedHTML(userCSS:)

    /// Returns a single HTML document concatenating all spine items.
    /// Each item's <body> content is wrapped in a <section> with a
    /// data-spine-index attribute for JS reference. userCSS is injected once.
    /// - Parameter spineIndexOffset: Added to each item's own `index` when emitting
    ///   `data-spine-index`. Single-book reads always pass 0, so `data-spine-index`
    ///   matches `item.index` exactly as before. Multi-work series reads pass the
    ///   running count of spine items already emitted by prior works, so the merged
    ///   document's `data-spine-index` values are unique across the whole series
    ///   rather than colliding at each work's own 0-based index. This does not
    ///   change `item.index` itself or anything keyed off it internally (e.g.
    ///   `isFirstSpineItem`); it only affects the attribute written into the HTML,
    ///   which is what JS position/annotation code reads.
    /// - Parameter removeParagraphIndents: See `html(for:removeParagraphIndents:)`
    ///   — same literal-whitespace stripping, applied here so both the
    ///   scroll-mode reader and the RSS/JSON feed server (which both call
    ///   this via `mergedHTML`) respect the preference identically. Feeds
    ///   previously ignored it entirely, since it was only ever expressed as
    ///   reader CSS that never reached feed output.
    func mergedHTML(
        userCSS: String,
        ao3Record: AO3MetadataRecord? = nil,
        spineIndexOffset: Int = 0,
        imageBaseOverride: URL? = nil,
        removeParagraphIndents: Bool = false
    ) throws -> String {
        let archive = try openArchive()

        // 1. Read entries sequentially from archive (ZIP archive access is thread-confined)
        struct SpinePayload {
            let index: Int
            let id: String
            let rawHTML: String
        }

        var payloads: [SpinePayload] = []
        payloads.reserveCapacity(spine.count)

        for item in spine {
            guard let entry = archive[item.href],
                  let data  = Self.extract(entry, from: archive)
            else { continue }

            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            payloads.append(SpinePayload(index: item.index, id: item.id, rawHTML: raw))
        }

        // 2. Parallel SwiftSoup sanitization and extraction across multi-core CPU pool
        let count = payloads.count
        var bodyChunks: [String] = Array(repeating: "", count: count)

        if count <= 1 {
            for index in 0..<count {
                let payload = payloads[index]
                var bodyContent = Self.extractBodyContent(
                    from: payload.rawHTML,
                    isFirstSpineItem: payload.index == 0,
                    removeParagraphIndents: removeParagraphIndents
                )
                if let imageBase = imageBaseOverride {
                    bodyContent = Self.rewriteImageReferences(in: bodyContent, imageBaseURL: imageBase)
                }
                let globalSpineIndex = payload.index + spineIndexOffset
                bodyChunks[index] = """
                <section data-spine-index="\(globalSpineIndex)" data-spine-id="\(payload.id)">
                \(bodyContent)
                </section>
                """
            }
        } else {
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let payload = payloads[index]
                var bodyContent = Self.extractBodyContent(
                    from: payload.rawHTML,
                    isFirstSpineItem: payload.index == 0,
                    removeParagraphIndents: removeParagraphIndents
                )
                if let imageBase = imageBaseOverride {
                    bodyContent = Self.rewriteImageReferences(in: bodyContent, imageBaseURL: imageBase)
                }
                let globalSpineIndex = payload.index + spineIndexOffset
                bodyChunks[index] = """
                <section data-spine-index="\(globalSpineIndex)" data-spine-id="\(payload.id)">
                \(bodyContent)
                </section>
                """
            }
        }

        if let record = ao3Record, let workURL = record.storyURL {
            bodyChunks.append(Self.buildAO3Endmatter(record: record, workURL: workURL))
        }

        let merged = bodyChunks.joined(separator: "\n")

        // Build a full document
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        \(userCSS)
        </style>
        </head>
        <body>
        \(merged)
        </body>
        </html>
        """
        return html
    }

    // MARK: - plainText(for:)

    /// Returns the plain text (no HTML tags) of a spine item.
    /// Character lengths are UTF-16 code units — matches the JS TreeWalker
    /// counting convention in PaginationJS and HighlightBridge.
    func plainText(for item: SpineItem) throws -> String {
        let archive = try openArchive()
        guard let entry = archive[item.href],
              let data  = Self.extract(entry, from: archive)
        else { throw EPUBError.missingSpineItem(item.href) }

        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return Self.stripAllTags(from: raw)
    }

    // MARK: - Sanitisation & Body extraction (package-internal for unit testing)

    /// Strip all active content and publisher CSS (link/style/style= attributes/script) using SwiftSoup,
    /// and inject userCSS before </head>. Sets window.currentSpineIndex for JS.
    static func sanitise(
        _ xhtml: String,
        userCSS: String,
        spineIndex: Int,
        removeParagraphIndents: Bool = false
    ) -> String {
        guard let doc = parseDocument(xhtml) else {
            return fallbackSanitise(xhtml, userCSS: userCSS, spineIndex: spineIndex)
        }

        cleanDOM(doc, removeParagraphIndents: removeParagraphIndents)

        // Inject user CSS + spine index tracker into head
        let head = doc.head() ?? {
            let newHead = Element(Tag("head"), "")
            _ = try? doc.children().first()?.prependChild(newHead)
            return newHead
        }()

        let styleElement = Element(Tag("style"), "")
        _ = try? styleElement.text(userCSS)
        _ = try? head.appendChild(styleElement)

        let scriptElement = Element(Tag("script"), "")
        _ = try? scriptElement.text("window.currentSpineIndex = \(spineIndex);")
        _ = try? head.appendChild(scriptElement)

        return (try? doc.outerHtml()) ?? xhtml
    }

    /// Extracts the content between <body> and </body> tags, or the whole string if not found,
    /// after stripping publisher CSS, styles, and active content.
    static func extractBodyContent(
        from xhtml: String,
        isFirstSpineItem: Bool,
        removeParagraphIndents: Bool = false
    ) -> String {
        guard let doc = parseDocument(xhtml) else {
            return fallbackExtractBodyContent(
                from: xhtml,
                isFirstSpineItem: isFirstSpineItem,
                removeParagraphIndents: removeParagraphIndents
            )
        }

        cleanDOM(doc, removeParagraphIndents: removeParagraphIndents)

        if isFirstSpineItem {
            stripPrefaceHeadingDOM(in: doc)
        }

        if let body = doc.body() {
            return (try? body.html()) ?? ""
        }
        return (try? doc.html()) ?? ""
    }

    /// Parses XHTML/HTML using SwiftSoup XML parser first, falling back to HTML parser.
    private static func parseDocument(_ xhtml: String) -> Document? {
        if let doc = try? Parser.xmlParser().parseInput(xhtml, "") {
            _ = doc.outputSettings().prettyPrint(pretty: false).syntax(syntax: .html).charset(.utf8)
            return doc
        }
        if let doc = try? Parser.htmlParser().parseInput(xhtml, "") {
            _ = doc.outputSettings().prettyPrint(pretty: false).syntax(syntax: .html).charset(.utf8)
            return doc
        }
        return nil
    }

    /// Single-pass DOM cleaning: strips stylesheet links, style blocks, inline styles, scripts,
    /// and active attributes (event handlers, javascript: URLs).
    private static func cleanDOM(_ doc: Document, removeParagraphIndents: Bool) {
        // 1. Remove active and styling elements
        if let elementsToRemove = try? doc.select("link[rel*='stylesheet'], link[rel*='Stylesheet'], style, script, iframe, object, embed, base") {
            for el in elementsToRemove {
                _ = try? el.remove()
            }
        }

        // 2. Remove inline style attributes and JavaScript event handlers / javascript: URLs
        if let allElements = try? doc.getAllElements() {
            let urlAttrs: Set<String> = ["href", "src", "xlink:href", "action", "data"]
            for el in allElements {
                if el.hasAttr("style") {
                    _ = try? el.removeAttr("style")
                }
                guard let attrs = el.getAttributes() else { continue }
                for attr in attrs.asList() {
                    let key = attr.getKey()
                    let lower = key.lowercased()
                    if lower.hasPrefix("on") || lower == "srcdoc" {
                        _ = try? el.removeAttr(key)
                        continue
                    }
                    if urlAttrs.contains(lower) {
                        let val = attr.getValue().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if val.hasPrefix("javascript:") {
                            _ = try? el.removeAttr(key)
                        }
                    }
                }
            }
        }

        // 3. Strip leading indentation whitespace if requested
        if removeParagraphIndents {
            stripLeadingIndentWhitespaceDOM(in: doc)
        }
    }

    /// Strips leading whitespace runs inside paragraph-like elements.
    private static func stripLeadingIndentWhitespaceDOM(in doc: Document) {
        guard let elements = try? doc.select("p, div, li, h1, h2, h3, h4, h5, h6, blockquote, td, th") else { return }
        for el in elements {
            guard let firstNode = el.getChildNodes().first as? TextNode else { continue }
            let whole = firstNode.getWholeText()
            var idx = whole.startIndex
            while idx < whole.endIndex && (whole[idx] == " " || whole[idx] == "\t") {
                idx = whole.index(after: idx)
            }
            if idx > whole.startIndex {
                let trimmed = String(whole[idx...])
                firstNode.text(trimmed)
            }
        }
    }

    /// Strips redundant "Preface" heading from the first spine item.
    private static func stripPrefaceHeadingDOM(in doc: Document) {
        guard let headings = try? doc.select("h1, h2, h3, h4, h5, h6") else { return }
        for heading in headings {
            let text = (try? heading.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.caseInsensitiveCompare("Preface") == .orderedSame {
                _ = try? heading.remove()
            }
        }
    }

    /// Fallback sanitisation using regular expressions if SwiftSoup parsing fails on severely malformed markup.
    private static func fallbackSanitise(
        _ xhtml: String,
        userCSS: String,
        spineIndex: Int
    ) -> String {
        var html = xhtml
        html = html.replacingOccurrences(
            of: #"<link[^>]+stylesheet[^>]*/?>|<link[^>]+rel\s*=\s*["']stylesheet["'][^>]*/?>"#,
            with: "", options: .regularExpression)
        html = html.replacingOccurrences(
            of: #"<style[^>]*>[\s\S]*?</style>"#,
            with: "", options: .regularExpression)
        html = html.replacingOccurrences(
            of: #"\s+style\s*=\s*"[^"]*""#,
            with: "", options: .regularExpression)
        html = html.replacingOccurrences(
            of: #"\s+style\s*=\s*'[^']*'"#,
            with: "", options: .regularExpression)
        html = html.replacingOccurrences(
            of: #"<script[^>]*>[\s\S]*?</script>"#,
            with: "", options: .regularExpression)

        let injection = """
        <style>
        \(userCSS)
        </style>
        <script>window.currentSpineIndex = \(spineIndex);</script>
        """
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: injection, at: range.lowerBound)
        } else if let range = html.range(of: "<body", options: .caseInsensitive) {
            html.insert(contentsOf: "<head>\(injection)</head>", at: range.lowerBound)
        } else {
            html = "<head>\(injection)</head>" + html
        }
        return html
    }

    /// Fallback body extraction using regular expressions if SwiftSoup parsing fails.
    private static func fallbackExtractBodyContent(
        from xhtml: String,
        isFirstSpineItem: Bool,
        removeParagraphIndents: Bool
    ) -> String {
        var html = fallbackSanitise(xhtml, userCSS: "", spineIndex: 0)
        if removeParagraphIndents {
            html = html.replacingOccurrences(
                of: #"(?i)(<(?:p|div|li|h[1-6]|blockquote|td|th)[^>]*>)[ \t]+"#,
                with: "$1", options: .regularExpression)
        }
        var body: String
        if let bodyStart = html.range(of: "<body", options: .caseInsensitive),
           let bodyTagEnd = html[bodyStart.lowerBound...].range(of: ">"),
           let bodyClose  = html.range(of: "</body>", options: .caseInsensitive) {
            body = String(html[bodyTagEnd.upperBound..<bodyClose.lowerBound])
        } else {
            body = html
        }
        if isFirstSpineItem {
            body = stripPrefaceHeading(body)
        }
        return body
    }

    /// Strips a redundant "Preface" heading (AO3 uses <h2 class="toc-heading">
    /// in practice, but the level varies; match h1-h6 with a backreference so
    /// only the matching close tag is eaten). Shared by fallbackExtractBodyContent
    /// and html(for:) so there is a single copy of this regex.
    private static func stripPrefaceHeading(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<(h[1-6])[^>]*>\s*[Pp]reface\s*</\1>"#,
            with: "", options: .regularExpression)
    }

    /// Builds the end-of-book AO3 endmatter: work URL, comment link, series links.
    /// Appended after the last spine item when an AO3MetadataRecord is available.
    private static func buildAO3Endmatter(record: AO3MetadataRecord, workURL: String) -> String {
        var lines: [String] = ["<section class=\"ao3-endmatter\">", "<hr>"]
        let commentsURL = "\(workURL)?show_comments=true#comments"
        lines.append("<p><a href=\"\(workURL)\">Read on AO3</a> • <a href=\"\(commentsURL)\">Comments on AO3</a></p>")

        for entry in record.series {
            guard let ao3ID = entry.ao3ID else { continue }
            let seriesURL = "https://archiveofourown.org/series/\(ao3ID)"
            lines.append("<p>Part \(entry.index) of <a href=\"\(seriesURL)\">\(entry.name)</a></p>")
        }

        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    /// Strips all HTML tags, returning raw text content only.
    /// Used for UTF-16 offset arithmetic — must match JS TreeWalker text-node iteration.
    private static func stripAllTags(from html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }
}
