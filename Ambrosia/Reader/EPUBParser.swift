import Foundation
import ZIPFoundation

// MARK: - Character Offset Invariant
//
// ALL character offset values in this project use the following convention:
//   UTF-16 code units, text node content only, HTML tags excluded.
//
// This convention MUST be consistent across:
//   EPUBParser  (plainText(for:))
//   PaginationJS (countAllTextChars, getCharOffset, renderPage)
//   HighlightBridge (restoreHighlights JS injection)
//   BookmarkManager (jump-to-position JS injection)
//
// Any deviation between Swift and JS offset counting causes irreproducible
// position drift that is extremely difficult to debug. Never change one side
// without changing all others.

// MARK: - EPUBParser

/// Full EPUB parser for Ambrosia's reader engine.
/// Parses the OPF spine, extracts HTML for each item, sanitises publisher CSS,
/// extracts images to a temp directory, and provides plain-text representations
/// for offset arithmetic.
struct EPUBParser {

    let epubURL: URL

    // MARK: - SpineItem

    struct SpineItem: Equatable {
        let index: Int
        /// Resolved path within the ZIP archive (e.g. "OEBPS/chapter01.xhtml")
        let href: String
        let mediaType: String
        let id: String           // manifest id, for internal cross-referencing
    }

    // MARK: - Parsed data (mutating parse() fills these)

    private(set) var spine: [SpineItem] = []
    private(set) var title: String = ""
    private(set) var opfBasePath: String = ""   // e.g. "OEBPS"

    // MARK: - TOCEntry

    struct TOCEntry: Identifiable, Equatable {
        let id: String
        let title: String
        let spineIndex: Int   // local to this parser; caller offsets for global use
        let depth: Int        // 0 = top level
    }

    private(set) var toc: [TOCEntry] = []

    /// Set once by the caller after parse() and before any html(for:)/mergedHTML
    /// calls (architecture.md invariant 17: configure-once state, not a parameter
    /// threaded through every call). Used by html(for:) to strip the redundant
    /// preface heading and append AO3 endmatter on the last spine item, matching
    /// what mergedHTML already does for scroll mode.
    var ao3Record: AO3MetadataRecord?

    // MARK: - Errors

    enum EPUBError: Error, LocalizedError {
        case cannotOpenArchive
        case missingContainerXML
        case missingOPF(String)
        case emptySpine
        case missingSpineItem(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpenArchive:        return "Could not open EPUB archive."
            case .missingContainerXML:      return "Missing META-INF/container.xml."
            case .missingOPF(let p):        return "OPF not found at \(p)."
            case .emptySpine:               return "EPUB spine is empty."
            case .missingSpineItem(let h):  return "Spine item not found: \(h)."
            }
        }
    }

    // MARK: - parse()

    /// Parses container.xml → OPF → spine + title.
    /// Must be called before html(for:), mergedHTML(), or plainText(for:).
    mutating func parse() throws {
        let archive = try openArchive()

        // container.xml → OPF path
        guard let containerEntry = archive["META-INF/container.xml"],
              let containerData  = Self.extract(containerEntry, from: archive),
              let opfPath        = Self.parseOPFPath(from: containerData)
        else { throw EPUBError.missingContainerXML }

        // OPF → manifest + spine + title
        guard let opfEntry = archive[opfPath],
              let opfData  = Self.extract(opfEntry, from: archive)
        else { throw EPUBError.missingOPF(opfPath) }

        opfBasePath = (opfPath as NSString).deletingLastPathComponent

        let opfParser = FullOPFParser()
        let xmlParser = XMLParser(data: opfData)
        xmlParser.delegate = opfParser
        xmlParser.parse()

        title = opfParser.dcTitle ?? ""

        // Build spine in order
        var items: [SpineItem] = []
        for (idx, idref) in opfParser.spineIdrefs.enumerated() {
            if let href = opfParser.manifest[idref] {
                let resolvedHref = opfBasePath.isEmpty ? href : "\(opfBasePath)/\(href)"
                let mediaType = opfParser.manifestMediaTypes[idref] ?? "application/xhtml+xml"
                items.append(SpineItem(index: idx, href: resolvedHref, mediaType: mediaType, id: idref))
            }
        }

        guard !items.isEmpty else { throw EPUBError.emptySpine }
        spine = items

        toc = Self.parseTOC(archive: archive, opfParser: opfParser, spine: spine, opfBasePath: opfBasePath)
    }

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
    func html(for item: SpineItem, userCSS: String, globalSpineIndex: Int? = nil) throws -> String {
        let archive = try openArchive()
        guard let entry = archive[item.href],
              let data  = Self.extract(entry, from: archive)
        else { throw EPUBError.missingSpineItem(item.href) }

        let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        var s = Self.sanitise(raw, userCSS: userCSS, spineIndex: globalSpineIndex ?? item.index)

        // Match mergedHTML's per-item behaviour: strip the redundant "Preface"
        // heading on the first spine item (unconditional, not gated on
        // ao3Record — the heading is in the raw EPUB regardless of whether
        // Ambrosia extracted structured AO3 metadata for it).
        if item.index == 0 {
            s = Self.stripPrefaceHeading(s)
        }

        // Append AO3 endmatter on the last spine item, when available.
        if item.index == spine.count - 1,
           let record = ao3Record, let workURL = record.storyURL {
            let endmatter = Self.buildAO3Endmatter(record: record, workURL: workURL)
            if let bodyClose = s.range(of: "</body>", options: .caseInsensitive) {
                s.insert(contentsOf: endmatter, at: bodyClose.lowerBound)
            } else {
                s += endmatter
            }
        }

        return s
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
    func mergedHTML(
        userCSS: String,
        ao3Record: AO3MetadataRecord? = nil,
        spineIndexOffset: Int = 0,
        imageBaseOverride: URL? = nil
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
            var bodyContent = Self.extractBodyContent(from: raw, isFirstSpineItem: item.index == 0)
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

    // MARK: - Image extraction

    /// Extracts all image files from the EPUB archive into a per-book temp directory.
    /// Returns the URL of that directory to pass as baseURL to WKWebView.loadHTMLString.
    ///
    /// Temp path: <tmpDir>/ambrosia/<calibreID>/
    /// Cleaned up in AppDelegate.applicationWillTerminate.
    @discardableResult
    static func extractImages(from epubURL: URL, calibreID: Int) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia")
            .appendingPathComponent("\(calibreID)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "svg", "webp", "bmp"]
        let archive = try Archive(url: epubURL, accessMode: .read)

        for entry in archive {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            // Flatten: just the filename, so baseURL resolves them via href="images/foo.png"
            // We must preserve relative paths from OPF base so src= attributes resolve correctly.
            let dest = tmp.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            _ = try archive.extract(entry, to: dest)
        }
        return tmp
    }

    // MARK: - TOC parsing

    /// Resolution order: EPUB3 nav document, then EPUB2 NCX, then a synthesized
    /// one-entry-per-spine-item fallback. If a TOC entry's href cannot be matched
    /// to a spine item, that entry is dropped rather than defaulted to index 0 —
    /// a silently-wrong jump target is worse than a visibly-missing entry.
    private static func parseTOC(archive: Archive, opfParser: FullOPFParser, spine: [SpineItem], opfBasePath: String) -> [TOCEntry] {
        func resolvedPath(_ href: String) -> String {
            opfBasePath.isEmpty ? href : "\(opfBasePath)/\(href)"
        }
        func spineIndex(forHref href: String) -> Int? {
            let stripped = href.components(separatedBy: "#").first ?? href
            let resolved = resolvedPath(stripped)
            return spine.first(where: { $0.href == resolved })?.index
        }

        // EPUB3 nav document
        if let navID = opfParser.manifestProperties.first(where: { key, value in
            value.split(separator: " ").map(String.init).contains("nav")
        })?.key, let navHref = opfParser.manifest[navID] {
            let navPath = resolvedPath(navHref)
            if let entry = archive[navPath], let data = Self.extract(entry, from: archive) {
                let navBasePath = (navPath as NSString).deletingLastPathComponent
                let delegate = NavTOCParser()
                let xmlParser = XMLParser(data: data)
                xmlParser.delegate = delegate
                xmlParser.parse()
                var entries: [TOCEntry] = []
                for item in delegate.entries {
                    let hrefRelativeToOPF = navBasePath.isEmpty ? item.href : "\(navBasePath)/\(item.href)"
                    // hrefRelativeToOPF may still contain "../" segments; standardize.
                    let standardized = URL(fileURLWithPath: "/\(hrefRelativeToOPF)").standardizedFileURL.path
                    let strippedForMatch = String(standardized.dropFirst())
                    let stripped = strippedForMatch.components(separatedBy: "#").first ?? strippedForMatch
                    guard let idx = spine.first(where: { $0.href == stripped })?.index else { continue }
                    entries.append(TOCEntry(id: item.id, title: item.title, spineIndex: idx, depth: item.depth))
                }
                if !entries.isEmpty { return entries }
            }
        }

        // EPUB2 NCX fallback
        if let ncxID = opfParser.manifestMediaTypes.first(where: { $0.value == "application/x-dtbncx+xml" })?.key,
           let ncxHref = opfParser.manifest[ncxID] {
            let ncxPath = resolvedPath(ncxHref)
            if let entry = archive[ncxPath], let data = Self.extract(entry, from: archive) {
                let delegate = NCXParser()
                let xmlParser = XMLParser(data: data)
                xmlParser.delegate = delegate
                xmlParser.parse()
                var entries: [TOCEntry] = []
                for item in delegate.entries {
                    guard let idx = spineIndex(forHref: item.href) else { continue }
                    entries.append(TOCEntry(id: item.id, title: item.title, spineIndex: idx, depth: item.depth))
                }
                if !entries.isEmpty { return entries }
            }
        }

        // Fallback: one entry per spine item
        return spine.enumerated().map { index, item in
            TOCEntry(id: item.id, title: "Chapter \(index + 1)", spineIndex: item.index, depth: 0)
        }
    }

    /// Rewrites `<img src="...">` and `<image xlink:href="...">` references to
    /// absolute `file://` URLs under `imageBaseURL`, for use in the merged
    /// multi-work document where a single relative baseURL can no longer resolve
    /// every work's images (each work has its own extracted image directory).
    /// Deliberately does not touch `<a href="...">` — in-book link resolution
    /// is handled separately by navigateToInternalLink and must keep seeing the
    /// original relative hrefs.
    private static func rewriteImageReferences(in html: String, imageBaseURL: URL) -> String {
        guard let encodedBase = imageBaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return html
        }
        var s = html
        s = s.replacingOccurrences(
            of: #"(<img[^>]+src\s*=\s*")(?!file://|https?://|data:)([^"]+)(")"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(<img[^>]+src\s*=\s*')(?!file://|https?://|data:)([^']+)(')"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(<image[^>]+xlink:href\s*=\s*")(?!file://|https?://|data:)([^"]+)(")"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(<image[^>]+xlink:href\s*=\s*')(?!file://|https?://|data:)([^']+)(')"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        return s
    }

    // MARK: - Private helpers

    private func openArchive() throws -> Archive {
        // Use the throwing initialiser directly — no do/catch wrapper, which would
        // cause the compiler to select the deprecated non-throwing overload instead.
        return try Archive(url: epubURL, accessMode: .read)
    }

    private static func extract(_ entry: Entry, from archive: Archive) -> Data? {
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    private static func parseOPFPath(from data: Data) -> String? {
        let p = ContainerParser()
        let x = XMLParser(data: data)
        x.delegate = p; x.parse()
        return p.rootfilePath
    }

    /// Strip all publisher CSS (link/style/style= attributes/script),
    /// inject userCSS before </head>. Sets window.currentSpineIndex for JS.
    private static func sanitise(_ xhtml: String, userCSS: String, spineIndex: Int) -> String {
        var s = xhtml

        // Remove stylesheet links
        s = s.replacingOccurrences(
            of: #"<link[^>]+stylesheet[^>]*/?>|<link[^>]+rel\s*=\s*["']stylesheet["'][^>]*/?>"#,
            with: "", options: .regularExpression)

        // Remove inline <style> blocks
        s = s.replacingOccurrences(
            of: #"<style[^>]*>[\s\S]*?</style>"#,
            with: "", options: .regularExpression)

        // Remove inline style= attributes
        s = s.replacingOccurrences(
            of: #"\s+style\s*=\s*"[^"]*""#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\s+style\s*=\s*'[^']*'"#,
            with: "", options: .regularExpression)

        // Remove <script> blocks
        s = s.replacingOccurrences(
            of: #"<script[^>]*>[\s\S]*?</script>"#,
            with: "", options: .regularExpression)

        // Inject user CSS + spine index tracker before </head>
        let injection = """
        <style>
        \(userCSS)
        </style>
        <script>window.currentSpineIndex = \(spineIndex);</script>
        """
        if let range = s.range(of: "</head>", options: .caseInsensitive) {
            s.insert(contentsOf: injection, at: range.lowerBound)
        } else if let range = s.range(of: "<body", options: .caseInsensitive) {
            s.insert(contentsOf: "<head>\(injection)</head>", at: range.lowerBound)
        } else {
            s = "<head>\(injection)</head>" + s
        }
        return s
    }

    /// Extracts the content between <body> and </body> tags, or the whole string if not found.
    private static func extractBodyContent(from xhtml: String, isFirstSpineItem: Bool) -> String {
        // Strip publisher CSS first so we don't drag styles into the merged doc
        var s = xhtml
        s = s.replacingOccurrences(
            of: #"<link[^>]+stylesheet[^>]*/?>|<link[^>]+rel\s*=\s*["']stylesheet["'][^>]*/?>"#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"<style[^>]*>[\s\S]*?</style>"#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\s+style\s*=\s*"[^"]*""#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\s+style\s*=\s*'[^']*'"#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"<script[^>]*>[\s\S]*?</script>"#,
            with: "", options: .regularExpression)

        // Extract body content
        var body: String
        if let bodyStart = s.range(of: "<body", options: .caseInsensitive),
           let bodyTagEnd = s[bodyStart.lowerBound...].range(of: ">"),
           let bodyClose  = s.range(of: "</body>", options: .caseInsensitive) {
            body = String(s[bodyTagEnd.upperBound..<bodyClose.lowerBound])
        } else {
            body = s
        }

        // AO3 EPUBs emit a redundant "Preface" heading on the first spine item;
        // the spine item is the preface by definition once rendered in Ambrosia.
        if isFirstSpineItem {
            body = stripPrefaceHeading(body)
        }

        return body
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

// MARK: - OPFDescriptionReader (kept for Calibre import use)

/// Extracts dc:description from an EPUB's OPF file.
/// Used during library scanning — runs on a background thread.
enum OPFDescriptionReader {

    static func read(from epubURL: URL) -> String? {
        do {
            let archive = try Archive(url: epubURL, accessMode: .read)

            guard let containerEntry = archive["META-INF/container.xml"],
                  let containerData  = extract(containerEntry, from: archive),
                  let opfPath        = parseOPFPath(from: containerData) else { return nil }

            guard let opfEntry = archive[opfPath],
                  let opfData  = extract(opfEntry, from: archive) else { return nil }

            return parseDCDescription(from: opfData)
        } catch {
            return nil
        }
    }

    private static func extract(_ entry: Entry, from archive: Archive) -> Data? {
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    private static func parseOPFPath(from data: Data) -> String? {
        let p = ContainerParser()
        let x = XMLParser(data: data)
        x.delegate = p; x.parse()
        return p.rootfilePath
    }

    private static func parseDCDescription(from data: Data) -> String? {
        let p = OPFParser()
        let x = XMLParser(data: data)
        x.delegate = p; x.parse()
        let raw = p.dcDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }
}

// MARK: - XML SAX Delegates

/// Parses META-INF/container.xml to extract the OPF rootfile path.
private class ContainerParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes attr: [String: String]) {
        if element == "rootfile", rootfilePath == nil {
            rootfilePath = attr["full-path"]
        }
    }
}

/// Parses OPF for dc:description only (used by OPFDescriptionReader).
private class OPFParser: NSObject, XMLParserDelegate {
    var dcDescription: String?
    private var inDescription = false
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes: [String: String] = [:]) {
        if element == "dc:description" || element == "description" {
            inDescription = true; buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inDescription { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inDescription, let str = String(data: CDATABlock, encoding: .utf8) { buffer += str }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName _: String?) {
        if (element == "dc:description" || element == "description"), inDescription {
            inDescription = false
            if dcDescription == nil,
               !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dcDescription = buffer
            }
        }
    }
}

/// Parses an EPUB3 nav document's `<nav epub:type="toc">` list, tracking
/// `<ol>` nesting depth for TOCEntry.depth.
private class NavTOCParser: NSObject, XMLParserDelegate {
    struct RawEntry {
        let id: String
        let title: String
        let href: String
        let depth: Int
    }

    var entries: [RawEntry] = []

    private var inTOCNav = false
    private var navDepth = 0        // nesting depth of <nav> elements, to detect the matching close
    private var olDepth = -1        // -1 = not inside the toc <nav> at all
    private var pendingHref: String?
    private var inAnchor = false
    private var titleBuffer = ""
    private var counter = 0

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attr: [String: String]) {
        let local = Self.localName(element, qName)
        switch local {
        case "nav":
            navDepth += 1
            let type = attr["epub:type"] ?? attr["type"]
            if !inTOCNav, type?.split(separator: " ").map(String.init).contains("toc") ?? false {
                inTOCNav = true
                olDepth = 0
            }
        case "ol" where inTOCNav:
            olDepth += 1
        case "a" where inTOCNav:
            inAnchor = true
            titleBuffer = ""
            pendingHref = attr["href"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAnchor { titleBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = Self.localName(element, qName)
        switch local {
        case "nav":
            navDepth -= 1
            if inTOCNav && navDepth == 0 { inTOCNav = false; olDepth = -1 }
        case "ol" where inTOCNav:
            olDepth -= 1
        case "a" where inTOCNav:
            inAnchor = false
            let trimmed = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = pendingHref, !href.isEmpty, !trimmed.isEmpty {
                counter += 1
                entries.append(RawEntry(id: "nav-\(counter)", title: trimmed, href: href, depth: max(0, olDepth - 1)))
            }
            pendingHref = nil
        default:
            break
        }
    }

    private static func localName(_ element: String, _ qName: String?) -> String {
        let name = qName ?? element
        if let range = name.range(of: ":") {
            return String(name[range.upperBound...])
        }
        return name
    }
}

/// Parses an EPUB2 NCX document's `<navPoint>` tree, tracking nesting depth.
private class NCXParser: NSObject, XMLParserDelegate {
    struct RawEntry {
        let id: String
        let title: String
        let href: String
        let depth: Int
    }

    var entries: [RawEntry] = []

    private var depth = -1
    private var inNavLabelText = false
    private var titleBuffer = ""
    private var pendingID: String?
    private var pendingHref: String?
    private var pendingTitle: String?

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes attr: [String: String]) {
        switch element {
        case "navPoint":
            depth += 1
            pendingID = attr["id"]
            pendingHref = nil
            pendingTitle = nil
        case "content":
            if pendingHref == nil { pendingHref = attr["src"] }
        case "text":
            inNavLabelText = true
            titleBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inNavLabelText { titleBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName _: String?) {
        switch element {
        case "text":
            if inNavLabelText {
                inNavLabelText = false
                if pendingTitle == nil {
                    let trimmed = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { pendingTitle = trimmed }
                }
            }
        case "navPoint":
            if let id = pendingID, let href = pendingHref, let title = pendingTitle {
                entries.append(RawEntry(id: id, title: title, href: href, depth: max(0, depth)))
            }
            depth -= 1
        default:
            break
        }
    }
}

/// Full OPF parser: extracts manifest (id→href, id→mediaType), spine order, and dc:title.
private class FullOPFParser: NSObject, XMLParserDelegate {
    /// manifest id → href (relative to OPF directory)
    var manifest: [String: String] = [:]
    /// manifest id → media-type
    var manifestMediaTypes: [String: String] = [:]
    /// manifest id → properties attribute (space-separated token list, e.g. "nav")
    var manifestProperties: [String: String] = [:]
    /// spine idrefs in document order
    var spineIdrefs: [String] = []
    /// dc:title value
    var dcTitle: String?

    private var inManifest  = false
    private var inSpine     = false
    private var inTitle     = false
    private var titleBuffer = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes attr: [String: String]) {
        switch element {
        case "manifest":
            inManifest = true
        case "spine":
            inSpine = true
        case "item" where inManifest:
            if let id = attr["id"], let href = attr["href"] {
                manifest[id] = href
                manifestMediaTypes[id] = attr["media-type"] ?? "application/xhtml+xml"
                manifestProperties[id] = attr["properties"]
            }
        case "itemref" where inSpine:
            // linear="no" items are still included — they may be author notes etc.
            if let idref = attr["idref"] {
                spineIdrefs.append(idref)
            }
        case "dc:title", "title":
            if dcTitle == nil { inTitle = true; titleBuffer = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titleBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName _: String?) {
        switch element {
        case "manifest":  inManifest = false
        case "spine":     inSpine    = false
        case "dc:title", "title":
            if inTitle {
                inTitle = false
                let trimmed = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { dcTitle = trimmed }
            }
        default: break
        }
    }
}
