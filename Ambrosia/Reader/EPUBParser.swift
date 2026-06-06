import Foundation
import ZIPFoundation

// MARK: - OPF Description Reader

/// Extracts dc:description from an EPUB's OPF file.
/// Runs on a background thread during import — no main-thread dependency.
///
/// AO3 EPUB structure:
///   META-INF/container.xml → OPF path → <dc:description> contains the summary.
///
/// The description is HTML (AO3 wraps it in <p> tags). HTMLStripper converts
/// it to plain text for display; the raw HTML is kept in Book.comments for
/// future rich-text rendering.
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

    // MARK: - Private

    private static func extract(_ entry: Entry, from archive: Archive) -> Data? {
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    private static func parseOPFPath(from data: Data) -> String? {
        let p = ContainerParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.rootfilePath
    }

    private static func parseDCDescription(from data: Data) -> String? {
        let p = OPFParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        let raw = p.dcDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }
}

// MARK: - XML delegates

private class ContainerParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?
    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        if element == "rootfile", rootfilePath == nil {
            rootfilePath = attributes["full-path"]
        }
    }
}

private class OPFParser: NSObject, XMLParserDelegate {
    var dcDescription: String?
    private var inDescription = false
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        if element == "dc:description" || element == "description" {
            inDescription = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inDescription { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inDescription,
           let str = String(data: CDATABlock, encoding: .utf8) {
            buffer += str
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if (element == "dc:description" || element == "description"), inDescription {
            inDescription = false
            if dcDescription == nil, !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dcDescription = buffer
            }
        }
    }
}

// MARK: - EPUBLoader

/// Minimal EPUB loader used by ReaderViewController (Phase 3 stub).
/// Reads the first spine item and returns sanitised HTML with all
/// publisher CSS stripped — ready to load into a WKWebView.
///
/// Full multi-spine pagination is implemented in Phase 4.
enum EPUBLoader {

    enum EPUBError: Error, LocalizedError {
        case cannotOpenArchive
        case missingContainerXML
        case missingOPF(String)
        case emptySpine

        var errorDescription: String? {
            switch self {
            case .cannotOpenArchive:    return "Could not open EPUB archive."
            case .missingContainerXML: return "Missing META-INF/container.xml."
            case .missingOPF(let p):   return "OPF file not found at \(p)."
            case .emptySpine:          return "EPUB spine is empty."
            }
        }
    }

    /// Returns sanitised HTML for the first spine item.
    static func loadFirstSpineHTML(from epubURL: URL) throws -> String {
        let archive = try Archive(url: epubURL, accessMode: .read)

        // 1. container.xml → OPF path
        guard let containerEntry = archive["META-INF/container.xml"],
              let containerData  = extract(containerEntry, from: archive),
              let opfPath        = parseOPFPath(from: containerData)
        else { throw EPUBError.missingContainerXML }

        // 2. OPF → manifest + spine
        guard let opfEntry = archive[opfPath],
              let opfData  = extract(opfEntry, from: archive)
        else { throw EPUBError.missingOPF(opfPath) }

        let opfBase   = (opfPath as NSString).deletingLastPathComponent
        let spineHref = try firstSpineHref(from: opfData, opfBase: opfBase)

        // 3. Read and sanitise the spine document
        guard let itemEntry = archive[spineHref],
              let itemData  = extract(itemEntry, from: archive)
        else { throw EPUBError.missingOPF(spineHref) }

        let raw = String(data: itemData, encoding: .utf8)
               ?? String(data: itemData, encoding: .isoLatin1)
               ?? ""
        return sanitise(raw)
    }

    // MARK: - Private helpers

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

    private static func firstSpineHref(from opfData: Data, opfBase: String) throws -> String {
        let p = SpineParser()
        let x = XMLParser(data: opfData)
        x.delegate = p; x.parse()
        guard let idref = p.firstSpineIdref,
              let href  = p.manifest[idref]
        else { throw EPUBError.emptySpine }
        return opfBase.isEmpty ? href : "\(opfBase)/\(href)"
    }

    /// Strip all publisher CSS and scripts; inject a minimal readable style.
    private static func sanitise(_ xhtml: String) -> String {
        var s = xhtml
        // Remove stylesheet links, inline styles, scripts
        let patterns = [
            #"<link[^>]+stylesheet[^>]*/?>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
            #"\s+style\s*=\s*"[^"]*""#,
            #"<script[^>]*>[\s\S]*?</script>"#,
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Inject baseline readable CSS
        let css = """
        <style>
        html,body{background:#FFFDF6;color:#1A1A1A;font-family:Georgia,serif;
          font-size:18px;line-height:1.7;max-width:680px;margin:0 auto;padding:2em 1.5em;
          -webkit-font-smoothing:antialiased;}
        img{max-width:100%;height:auto;}
        p{margin:0 0 0.8em 0;}
        div,section,article{float:none!important;position:static!important;column-count:unset!important;}
        </style>
        """
        if let range = s.range(of: "</head>", options: .caseInsensitive) {
            s.insert(contentsOf: css, at: range.lowerBound)
        } else {
            s = css + s
        }
        return s
    }
}

// MARK: - OPF spine parser

private class SpineParser: NSObject, XMLParserDelegate {
    /// idref of the first spine itemref
    var firstSpineIdref: String?
    /// id → href from the manifest
    var manifest: [String: String] = [:]

    private var inSpine    = false
    private var inManifest = false

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes attr: [String: String]) {
        switch element {
        case "manifest": inManifest = true
        case "spine":    inSpine    = true
        case "item" where inManifest:
            if let id = attr["id"], let href = attr["href"] {
                manifest[id] = href
            }
        case "itemref" where inSpine:
            if firstSpineIdref == nil, let idref = attr["idref"] {
                firstSpineIdref = idref
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName _: String?) {
        if element == "manifest" { inManifest = false }
        if element == "spine"    { inSpine    = false }
    }
}
