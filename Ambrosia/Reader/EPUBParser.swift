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
    }

    // MARK: - html(for:userCSS:)

    /// Returns sanitised HTML for a single spine item, with publisher CSS stripped
    /// and userCSS injected before </head>.
    func html(for item: SpineItem, userCSS: String) throws -> String {
        let archive = try openArchive()
        guard let entry = archive[item.href],
              let data  = Self.extract(entry, from: archive)
        else { throw EPUBError.missingSpineItem(item.href) }

        let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        return Self.sanitise(raw, userCSS: userCSS, spineIndex: item.index)
    }

    // MARK: - mergedHTML(userCSS:)

    /// Returns a single HTML document concatenating all spine items.
    /// Each item's <body> content is wrapped in a <section> with a
    /// data-spine-index attribute for JS reference. userCSS is injected once.
    func mergedHTML(userCSS: String) throws -> String {
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
            let bodyContent = Self.extractBodyContent(from: raw)
            bodyChunks.append("""
            <section data-spine-index="\(item.index)" data-spine-id="\(item.id)">
            \(bodyContent)
            </section>
            """)
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

    // MARK: - Private helpers

    private func openArchive() throws -> Archive {
        guard let archive = try? Archive(url: epubURL, accessMode: .read) else {
            throw EPUBError.cannotOpenArchive
        }
        return archive
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
    private static func extractBodyContent(from xhtml: String) -> String {
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
        if let bodyStart = s.range(of: "<body", options: .caseInsensitive),
           let bodyTagEnd = s[bodyStart.lowerBound...].range(of: ">"),
           let bodyClose  = s.range(of: "</body>", options: .caseInsensitive) {
            return String(s[bodyTagEnd.upperBound..<bodyClose.lowerBound])
        }
        return s
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

/// Full OPF parser: extracts manifest (id→href, id→mediaType), spine order, and dc:title.
private class FullOPFParser: NSObject, XMLParserDelegate {
    /// manifest id → href (relative to OPF directory)
    var manifest: [String: String] = [:]
    /// manifest id → media-type
    var manifestMediaTypes: [String: String] = [:]
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
