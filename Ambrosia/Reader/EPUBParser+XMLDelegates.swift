import Foundation

// MARK: - XML SAX Delegates
//
// Split out of EPUBParser.swift to stay under SwiftLint's file_length limit.
// MARK: - XML SAX Delegates

/// Parses META-INF/container.xml to extract the OPF rootfile path.
class ContainerParser: NSObject, XMLParserDelegate {
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
class OPFParser: NSObject, XMLParserDelegate {
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
        if element == "dc:description" || element == "description", inDescription {
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
class NavTOCParser: NSObject, XMLParserDelegate {
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
class NCXParser: NSObject, XMLParserDelegate {
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
class FullOPFParser: NSObject, XMLParserDelegate {
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
