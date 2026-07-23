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

/// Full OPF parser: extracts manifest (id→href, id→mediaType), spine order, dc:title, dc:creator,
/// and (§7.2, Phase 6) dc:description, dc:date, dc:publisher, dc:subject — all in the same single pass.
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
    /// dc:creator values, in document order. The OPF spec allows multiple
    /// `<dc:creator>` elements; one element may itself hold a comma-joined
    /// list of names (observed AO3 export shape), so this captures each
    /// element's raw text without splitting it further — callers decide how
    /// to split.
    var dcCreators: [String] = []
    /// dc:description value (§7.2). First non-empty element wins, same
    /// first-wins convention as dcTitle.
    var dcDescription: String?
    /// dc:date value (§7.2), captured as raw text — not yet parsed/validated
    /// as ISO-8601; see book_index.pub_date.
    var dcDate: String?
    /// dc:publisher value (§7.2).
    var dcPublisher: String?
    /// dc:subject value (§7.2). The OPF spec allows multiple `<dc:subject>`
    /// elements; joined with ", " the same way dcCreators' individual
    /// elements are captured whole rather than split.
    var dcSubjects: [String] = []

    private var inManifest  = false
    private var inSpine     = false
    private var inTitle     = false
    private var titleBuffer = ""
    private var inCreator     = false
    private var creatorBuffer = ""
    private var inDescription  = false
    private var descriptionBuffer = ""
    private var inDate         = false
    private var dateBuffer     = ""
    private var inPublisher    = false
    private var publisherBuffer = ""
    private var inSubject      = false
    private var subjectBuffer  = ""

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
        case "dc:creator", "creator":
            inCreator = true; creatorBuffer = ""
        case "dc:description", "description":
            if dcDescription == nil { inDescription = true; descriptionBuffer = "" }
        case "dc:date", "date":
            if dcDate == nil { inDate = true; dateBuffer = "" }
        case "dc:publisher", "publisher":
            if dcPublisher == nil { inPublisher = true; publisherBuffer = "" }
        case "dc:subject", "subject":
            inSubject = true; subjectBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titleBuffer += string }
        if inCreator { creatorBuffer += string }
        if inDescription { descriptionBuffer += string }
        if inDate { dateBuffer += string }
        if inPublisher { publisherBuffer += string }
        if inSubject { subjectBuffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inDescription, let str = String(data: CDATABlock, encoding: .utf8) { descriptionBuffer += str }
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
        case "dc:creator", "creator":
            if inCreator {
                inCreator = false
                let trimmed = creatorBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { dcCreators.append(trimmed) }
            }
        case "dc:description", "description":
            if inDescription {
                inDescription = false
                let trimmed = descriptionBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if dcDescription == nil, !trimmed.isEmpty { dcDescription = trimmed }
            }
        case "dc:date", "date":
            if inDate {
                inDate = false
                let trimmed = dateBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if dcDate == nil, !trimmed.isEmpty { dcDate = trimmed }
            }
        case "dc:publisher", "publisher":
            if inPublisher {
                inPublisher = false
                let trimmed = publisherBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if dcPublisher == nil, !trimmed.isEmpty { dcPublisher = trimmed }
            }
        case "dc:subject", "subject":
            if inSubject {
                inSubject = false
                let trimmed = subjectBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { dcSubjects.append(trimmed) }
            }
        default: break
        }
    }
}
