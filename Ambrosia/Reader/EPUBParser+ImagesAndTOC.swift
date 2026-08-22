import Foundation
import ZIPFoundation

// MARK: - EPUBParser image extraction & TOC parsing
//
// Split out of EPUBParser.swift to stay under SwiftLint's file_length limit.
extension EPUBParser {

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

    /// Rewrites `<img src="...">` and `<image xlink:href="...">` references to
    /// absolute `file://` URLs under `imageBaseURL`, for use in the merged
    /// multi-work document where a single relative baseURL can no longer resolve
    /// every work's images (each work has its own extracted image directory).
    /// Deliberately does not touch `<a href="...">` — in-book link resolution
    /// is handled separately by navigateToInternalLink and must keep seeing the
    /// original relative hrefs.
    ///
    /// Not private: called from EPUBParser+Rendering.swift's mergedHTML(...).
    static func rewriteImageReferences(in html: String, imageBaseURL: URL) -> String {
        guard let encodedBase = imageBaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return html
        }
        var result = html
        result = result.replacingOccurrences(
            of: #"(<img[^>]+src\s*=\s*")(?!file://|https?://|data:)([^"]+)(")"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(<img[^>]+src\s*=\s*')(?!file://|https?://|data:)([^']+)(')"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(<image[^>]+xlink:href\s*=\s*")(?!file://|https?://|data:)([^"]+)(")"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(<image[^>]+xlink:href\s*=\s*')(?!file://|https?://|data:)([^']+)(')"#,
            with: "$1file://\(encodedBase)/$2$3",
            options: .regularExpression)
        return result
    }

    // MARK: - TOC parsing

    /// Resolution order: EPUB3 nav document, then EPUB2 NCX, then a synthesized
    /// one-entry-per-spine-item fallback. If a TOC entry's href cannot be matched
    /// to a spine item, that entry is dropped rather than defaulted to index 0 —
    /// a silently-wrong jump target is worse than a visibly-missing entry.
    ///
    /// Not private: called from EPUBParser.swift's parse().
    static func parseTOC(archive: Archive, opfParser: FullOPFParser, spine: [SpineItem], opfBasePath: String) -> [TOCEntry] {
        func resolvedPath(_ href: String) -> String {
            opfBasePath.isEmpty ? href : "\(opfBasePath)/\(href)"
        }
        func spineIndex(forHref href: String) -> Int? {
            let stripped = href.components(separatedBy: "#").first ?? href
            let resolved = resolvedPath(stripped)
            return spine.first(where: { $0.href == resolved })?.index
        }

        // EPUB3 nav document
        if let navID = opfParser.manifestProperties.first(where: { _, value in
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
}
