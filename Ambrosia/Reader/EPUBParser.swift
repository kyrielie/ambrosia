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
//
// Any deviation between Swift and JS offset counting causes irreproducible
// position drift that is extremely difficult to debug. Never change one side
// without changing all others.

// MARK: - EPUBParser

/// Full EPUB parser for Ambrosia's reader engine.
/// Parses the OPF spine, extracts HTML for each item, sanitises publisher CSS,
/// extracts images to a temp directory, and provides plain-text representations
/// for offset arithmetic.
///
/// Split across several files to stay under SwiftLint's file_length limit:
/// this file (core types + parse()), EPUBParser+Rendering.swift (html/mergedHTML/
/// plainText + their private helpers), EPUBParser+ImagesAndTOC.swift (image
/// extraction, TOC parsing), and EPUBParser+XMLDelegates.swift (the private
/// XMLParserDelegate classes).
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
    /// Raw `dc:creator` element text, in document order, one element per
    /// entry (an element may itself hold a comma-joined list of names —
    /// see `FullOPFParser.dcCreators`). Populated by `parse()` alongside
    /// `title`, since the OPF is already being parsed for spine/title.
    private(set) var opfCreators: [String] = []
    /// dc:description, dc:date, dc:publisher, dc:subject — captured in the same
    /// single OPF parse pass as title/opfCreators (§7.2, Phase 6). Feeds
    /// BookIndexRecord in LibrarySession.extractOneBook; not otherwise wired
    /// into any filter/sort/UI surface in this phase (§7.4).
    private(set) var opfDescription: String?
    private(set) var opfDate: String?
    private(set) var opfPublisher: String?
    private(set) var opfSubjects: [String] = []

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
            case .cannotOpenArchive:          return "Could not open EPUB archive."
            case .missingContainerXML:        return "Missing META-INF/container.xml."
            case .missingOPF(let path):       return "OPF not found at \(path)."
            case .emptySpine:                 return "EPUB spine is empty."
            case .missingSpineItem(let href): return "Spine item not found: \(href)."
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
        opfCreators = opfParser.dcCreators
        opfDescription = opfParser.dcDescription
        opfDate = opfParser.dcDate
        opfPublisher = opfParser.dcPublisher
        opfSubjects = opfParser.dcSubjects

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

    // MARK: - Shared archive helpers
    //
    // Not private: also called from the html(for:)/mergedHTML/plainText(for:)
    // extension in EPUBParser+Rendering.swift.

    func openArchive() throws -> Archive {
        // Use the throwing initialiser directly — no do/catch wrapper, which would
        // cause the compiler to select the deprecated non-throwing overload instead.
        return try Archive(url: epubURL, accessMode: .read)
    }

    static func extract(_ entry: Entry, from archive: Archive) -> Data? {
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    private static func parseOPFPath(from data: Data) -> String? {
        let containerParser = ContainerParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = containerParser
        xmlParser.parse()
        return containerParser.rootfilePath
    }
}
