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
