import ZIPFoundation
import Foundation

/// Validates that an EPUB file has the minimum structure required to open:
/// META-INF/container.xml → OPF file → all spine items present in the archive.
struct EPUBValidator {
    enum ValidationError: Error {
        case notReadable
        case missingContainerXML
        case missingOPF(String)
        case missingSpineItem(String)
    }

    static func isValid(at url: URL) -> Bool {
        return (try? validate(at: url)) != nil
    }

    static func validate(at url: URL) throws {
        // Use the throwing initializer (non-deprecated)
        let archive = try Archive(url: url, accessMode: .read)

        guard let containerEntry = archive["META-INF/container.xml"],
              let containerData = readEntry(containerEntry, from: archive) else {
            throw ValidationError.missingContainerXML
        }

        let opfPath = try parseOPFPath(from: containerData)

        guard let opfEntry = archive[opfPath],
              let opfData = readEntry(opfEntry, from: archive) else {
            throw ValidationError.missingOPF(opfPath)
        }

        let opfBase = (opfPath as NSString).deletingLastPathComponent
        let spineHrefs = try parseSpineHrefs(from: opfData, opfBasePath: opfBase)

        for href in spineHrefs {
            guard archive[href] != nil else {
                throw ValidationError.missingSpineItem(href)
            }
        }
    }

    // MARK: - Helpers

    private static func readEntry(_ entry: Entry, from archive: Archive) -> Data? {
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    private static func parseOPFPath(from containerData: Data) throws -> String {
        let parser = ContainerXMLParser()
        let xml = XMLParser(data: containerData)
        xml.delegate = parser
        xml.parse()
        guard let path = parser.rootfilePath else {
            throw ValidationError.missingContainerXML
        }
        return path
    }

    private static func parseSpineHrefs(from opfData: Data, opfBasePath: String) throws -> [String] {
        let parser = OPFSpineParser()
        let xml = XMLParser(data: opfData)
        xml.delegate = parser
        xml.parse()
        return parser.spineHrefs.map { href in
            opfBasePath.isEmpty ? href : "\(opfBasePath)/\(href)"
        }
    }
}

// MARK: - XML delegates

private class ContainerXMLParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?
    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if element == "rootfile", rootfilePath == nil {
            rootfilePath = attributes["full-path"]
        }
    }
}

private class OPFSpineParser: NSObject, XMLParserDelegate {
    var manifestItems: [String: String] = [:]
    var spineHrefs: [String] = []
    private var inSpine = false

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch element {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifestItems[id] = href
            }
        case "spine":
            inSpine = true
        case "itemref":
            if inSpine, let idref = attributes["idref"],
               let href = manifestItems[idref] {
                spineHrefs.append(href)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "spine" { inSpine = false }
    }
}
