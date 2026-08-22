import Foundation

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
        var bodyChunks: [String] = []

        for item in spine {
            guard let entry = archive[item.href],
                  let data  = Self.extract(entry, from: archive)
            else { continue }

            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            // Extract only the <body>…</body> content
            var bodyContent = Self.extractBodyContent(
                from: raw,
                isFirstSpineItem: item.index == 0,
                removeParagraphIndents: removeParagraphIndents
            )
            if let imageBase = imageBaseOverride {
                bodyContent = Self.rewriteImageReferences(in: bodyContent, imageBaseURL: imageBase)
            }
            let globalSpineIndex = item.index + spineIndexOffset
            bodyChunks.append("""
            <section data-spine-index="\(globalSpineIndex)" data-spine-id="\(item.id)">
            \(bodyContent)
            </section>
            """)
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

    // MARK: - Private rendering helpers

    /// Strip all publisher CSS (link/style/style= attributes/script),
    /// inject userCSS before </head>. Sets window.currentSpineIndex for JS.
    private static func sanitise(
        _ xhtml: String,
        userCSS: String,
        spineIndex: Int,
        removeParagraphIndents: Bool = false
    ) -> String {
        var html = xhtml

        // Remove stylesheet links
        html = html.replacingOccurrences(
            of: #"<link[^>]+stylesheet[^>]*/?>|<link[^>]+rel\s*=\s*["']stylesheet["'][^>]*/?>"#,
            with: "", options: .regularExpression)

        // Remove inline <style> blocks
        html = html.replacingOccurrences(
            of: #"<style[^>]*>[\s\S]*?</style>"#,
            with: "", options: .regularExpression)

        // Remove inline style= attributes
        html = html.replacingOccurrences(
            of: #"\s+style\s*=\s*"[^"]*""#,
            with: "", options: .regularExpression)
        html = html.replacingOccurrences(
            of: #"\s+style\s*=\s*'[^']*'"#,
            with: "", options: .regularExpression)

        // Remove <script> blocks
        html = html.replacingOccurrences(
            of: #"<script[^>]*>[\s\S]*?</script>"#,
            with: "", options: .regularExpression)

        // With publisher CSS gone, a leading indent can only be literal
        // whitespace left in the text — see stripLeadingIndentWhitespace.
        if removeParagraphIndents {
            html = Self.stripLeadingIndentWhitespace(html)
        }

        // Inject user CSS + spine index tracker before </head>
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

    /// Extracts the content between <body> and </body> tags, or the whole string if not found.
    private static func extractBodyContent(
        from xhtml: String,
        isFirstSpineItem: Bool,
        removeParagraphIndents: Bool = false
    ) -> String {
        // Strip publisher CSS first so we don't drag styles into the merged doc
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

        // With publisher CSS gone, a leading indent can only be literal
        // whitespace left in the text — see stripLeadingIndentWhitespace.
        // Shared by extractBodyContent (scroll mode + feeds) and sanitise
        // (paginated mode) so there's one definition of "indent" between them.
        if removeParagraphIndents {
            html = Self.stripLeadingIndentWhitespace(html)
        }

        // Extract body content
        var body: String
        if let bodyStart = html.range(of: "<body", options: .caseInsensitive),
           let bodyTagEnd = html[bodyStart.lowerBound...].range(of: ">"),
           let bodyClose  = html.range(of: "</body>", options: .caseInsensitive) {
            body = String(html[bodyTagEnd.upperBound..<bodyClose.lowerBound])
        } else {
            body = html
        }

        // AO3 EPUBs emit a redundant "Preface" heading on the first spine item;
        // the spine item is the preface by definition once rendered in Ambrosia.
        if isFirstSpineItem {
            body = stripPrefaceHeading(body)
        }

        return body
    }

    /// Strips leading space/tab runs immediately inside paragraph-like
    /// elements — the literal-whitespace equivalent of the old
    /// `text-indent: 0` CSS override, for books that fake first-line
    /// indentation with actual whitespace characters rather than CSS
    /// (publisher CSS never survives `sanitise`/`extractBodyContent`, so
    /// there's nothing left for a CSS override to cancel out). Scoped to the
    /// same element set the CSS rule targeted (`p, div, li`), extended to
    /// headings/blockquote/table cells since those are equally plausible
    /// homes for a converted-from-plaintext indent. Deliberately does not
    /// touch `&nbsp;`-based fake indents — a different, separate pattern.
    private static func stripLeadingIndentWhitespace(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"(?i)(<(?:p|div|li|h[1-6]|blockquote|td|th)[^>]*>)[ \t]+"#,
            with: "$1", options: .regularExpression)
    }

    /// Strips a redundant "Preface" heading (AO3 uses <h2 class="toc-heading">
    /// in practice, but the level varies; match h1-h6 with a backreference so
    /// only the matching close tag is eaten). Shared by extractBodyContent
    /// (scroll mode) and html(for:) (paginated mode) so there is a single copy
    /// of this regex — see architecture.md incident notes on drift between files.
    private static func stripPrefaceHeading(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<(h[1-6])[^>]*>\s*[Pp]reface\s*</\1>"#,
            with: "", options: .regularExpression)
    }

    /// Builds the end-of-book AO3 endmatter: work URL, comment link, series links.
    /// Appended after the last spine item when an AO3MetadataRecord is available.
    private static func buildAO3Endmatter(record: AO3MetadataRecord, workURL: String) -> String {
        var lines: [String] = ["<section class=\"ao3-endmatter\">", "<hr>"]
        lines.append("<p><a href=\"\(workURL)\">Read on AO3</a></p>")

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
