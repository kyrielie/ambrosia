import Foundation
import SwiftSoup

struct AO3MetadataRecord: Codable, Equatable, Sendable {
    struct SeriesEntry: Codable, Equatable, Sendable {
        let name: String
        let index: Int
        let ao3ID: String?
    }

    var storyURL: String?
    var workID: String?
    var authors: [AO3AuthorEntry]
    var kudosCount: Int?
    var wordCount: Int?
    var chapterCurrent: Int?
    var chapterTotal: Int?
    var isComplete: Bool
    var language: String?
    var publishedDate: String?
    var updatedDate: String?
    var fandoms: [String]
    var relationships: [String]
    var characters: [String]
    var additionalTags: [String]
    var categories: [String]
    var ao3Collections: [String]
    var series: [SeriesEntry]
    var rating: String?
    var warnings: [String]
    var extractedAt: String
}

/// One author credited on a work. AO3 works can list multiple authors
/// (co-authorships), including a mix of real accounts and `orphan_account`
/// placeholders in the same byline.
struct AO3AuthorEntry: Codable, Equatable, Sendable {
    /// Login account, or "orphan_account" / "Anonymous" verbatim.
    let username: String
    /// nil when the pseud equals the username, or unknown (fallback tiers).
    let pseud: String?
    /// nil only when not derivable (shouldn't happen for the byline tier).
    let profileURL: String?
    /// Where this entry came from — see `AO3AuthorSource`.
    let source: AO3AuthorSource
}

/// Provenance for an `AO3AuthorEntry`, in descending order of reliability.
/// Downstream code (backfill diagnostics, matching against Calibre's author
/// field) needs to tell these apart, so this is stored per-entry, not
/// inferred from context.
enum AO3AuthorSource: String, Codable, Sendable {
    /// AO3 chapter byline — structured, has an href.
    case byline
    /// EPUB `dc:creator` — name only, no href.
    case opfCreator
    /// Calibre's own author field — name only, last resort.
    case calibre
}

struct AO3ExtractionDiagnostic: Codable, Equatable, Sendable {
    let calibreID: Int
    let status: String
    let reason: String
    let epubPath: String?
    let epubFilename: String?
    let spineItemsChecked: Int?
    let attemptedAt: String
}

/// §7.1/§7.3 (Phase 6): one row per book where `EPUBParser.parse()` succeeds,
/// AO3 or not. `title`/`description`/`pubDate`/`publisher`/`subject` are
/// captured opportunistically from the same OPF parse pass and are not wired
/// into any filter/sort/UI surface in this phase (§7.4) — only `wordCount` is
/// a genuinely new capability (word count for non-AO3 books with no
/// configured custom column).
struct BookIndexRecord: Codable, Equatable, Sendable {
    let title: String?
    let description: String?
    /// Computed by summing word counts across the spine's plain text
    /// (`EPUBParser.plainText(for:)`); nil if uncountable.
    let wordCount: Int?
    /// dc:date, captured as raw text — not validated/parsed as ISO-8601.
    let pubDate: String?
    let publisher: String?
    /// dc:subject values, joined — the OPF spec allows multiple elements.
    let subject: String?
    let indexedAt: String
}

enum AO3MetadataExtractor {
    static func extract(from html: String) -> AO3MetadataRecord? {
        do {
            let doc = try SwiftSoup.parse(html)
            guard let meta = try doc.select("dl.tags").first() else { return nil }

            var record = AO3MetadataRecord(
                storyURL: nil,
                workID: nil,
                authors: [],
                kudosCount: nil,
                wordCount: nil,
                chapterCurrent: nil,
                chapterTotal: nil,
                isComplete: false,
                language: nil,
                publishedDate: nil,
                updatedDate: nil,
                fandoms: [],
                relationships: [],
                characters: [],
                additionalTags: [],
                categories: [],
                ao3Collections: [],
                series: [],
                rating: nil,
                warnings: [],
                extractedAt: ISO8601DateFormatter().string(from: Date())
            )

            if let link = try doc.select("p.message a[href*=\\/works\\/], p.message a[href*=works]").first() {
                let href = try link.attr("href")
                record.storyURL = absoluteAO3URL(href).replacingOccurrences(of: "http://", with: "https://")
                record.workID = firstMatch(in: href, pattern: #"/works/([0-9]+)"#)
            } else {
                let work = try firstHrefMatching(in: doc, pattern: #"/works/([0-9]+)"#)
                record.storyURL = work.href.map(absoluteAO3URL)
                record.workID = work.match
            }

            var completedDate: String?
            var currentField = ""
            for element in meta.children().array() {
                let tag = element.tagName().lowercased()
                if tag == "dt" {
                    currentField = normalisedField((try? element.text()) ?? "")
                } else if tag == "dd" {
                    parseField(currentField, element: element, into: &record, completedDate: &completedDate)
                }
            }

            if record.chapterCurrent == nil && record.chapterTotal == nil {
                record.chapterCurrent = 1
                record.chapterTotal = 1
            }

            record.isComplete = (
                record.chapterCurrent != nil &&
                record.chapterTotal != nil &&
                record.chapterCurrent == record.chapterTotal
            ) || completedDate != nil

            logMissingParsedFieldsIfNeeded(record)
            return record
        } catch {
            #if DEBUG
            print("[AO3MetadataExtractor] Parse failed: \(error)")
            #endif
            return nil
        }
    }

    private static func parseField(
        _ field: String,
        element: Element,
        into record: inout AO3MetadataRecord,
        completedDate: inout String?
    ) {
        switch field {
        case "language":
            record.language = (try? element.text()).flatMap(\.nilIfEmpty)
        case "fandom", "fandoms":
            record.fandoms = linkTexts(in: element)
        case "relationship", "relationships":
            record.relationships = linkTexts(in: element)
        case "character", "characters":
            record.characters = linkTexts(in: element)
        case "additional tag", "additional tags":
            record.additionalTags = linkTexts(in: element)
        case "category", "categories":
            record.categories = linkTexts(in: element).compactMap(canonicalCategoryText)
        case "rating", "ratings":
            record.rating = (try? element.text()).flatMap(\.nilIfEmpty).flatMap(canonicalRatingText)
        case "archive warning", "archive warnings", "warning", "warnings":
            record.warnings = linkTexts(in: element).compactMap(canonicalWarningText)
        case "collection", "collections":
            record.ao3Collections = linkTexts(in: element)
        case "series":
            record.series = parseEPUBSeries(in: element)
        case "words":
            record.wordCount = parseInt((try? element.text()) ?? "")
        case "chapters":
            let chapters = parseChapters((try? element.text()) ?? "")
            record.chapterCurrent = chapters.current
            record.chapterTotal = chapters.total
        case "stats":
            parseStats((try? element.text()) ?? "", into: &record, completedDate: &completedDate)
        default:
            break
        }
    }

    private static func parseStats(_ text: String, into record: inout AO3MetadataRecord, completedDate: inout String?) {
        let tokens = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var index = 0
        while index < tokens.count - 1 {
            let key = tokens[index].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let value = tokens[index + 1]
            switch key.lowercased() {
            case "published":
                record.publishedDate = value
            case "completed":
                completedDate = value
                record.updatedDate = value
            case "updated":
                record.updatedDate = value
            case "words":
                record.wordCount = parseInt(value)
            case "chapters":
                let chapters = parseChapters(value)
                record.chapterCurrent = chapters.current
                record.chapterTotal = chapters.total
            case "kudos":
                record.kudosCount = parseInt(value)
            default:
                break
            }
            index += 2
        }
    }

    private static func normalisedField(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    private static func linkTexts(in element: Element) -> [String] {
        (try? element.select("a").array().compactMap { try $0.text().nilIfEmpty }) ?? []
    }

    /// Validates preface rating text against the closed AO3Rating set. Unrecognized
    /// text (a wording change upstream, or malformed markup) is dropped rather than
    /// stored as an unvalidated free string.
    private static func canonicalRatingText(_ text: String) -> String? {
        AO3Rating(rawValue: text)?.rawValue
    }

    /// Validates preface category text against the closed AO3Category set.
    private static func canonicalCategoryText(_ text: String) -> String? {
        AO3Category(rawValue: text)?.rawValue
    }

    /// Validates preface warning text against the closed AO3Warning set, folding the
    /// preface-only spelling "Creator Chose Not To Use Archive Warnings" into the
    /// single canonical `.chooseNotTo` value ("Choose Not To Use Archive Warnings")
    /// also used by Calibre tags, so both sources agree on one string.
    private static func canonicalWarningText(_ text: String) -> String? {
        let normalized = text == "Creator Chose Not To Use Archive Warnings"
            ? "Choose Not To Use Archive Warnings"
            : text
        return AO3Warning(rawValue: normalized)?.rawValue
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseChapters(_ value: String?) -> (current: Int?, total: Int?) {
        guard let value else { return (nil, nil) }
        let parts = value.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (Int(parts.first ?? ""), parts.count > 1 && parts[1] != "?" ? Int(parts[1]) : nil)
    }

    private static func parseEPUBSeries(in element: Element) -> [AO3MetadataRecord.SeriesEntry] {
        var pendingIndex: Int?
        var series: [AO3MetadataRecord.SeriesEntry] = []
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                pendingIndex = firstMatch(in: textNode.text(), pattern: #"(?:,\s*)?[Pp]art\s+([0-9]+)\s+of"#).flatMap(Int.init)
            } else if let link = node as? Element, link.tagName().lowercased() == "a" {
                let name = (try? link.text()).flatMap(\.nilIfEmpty)
                let href = (try? link.attr("href")) ?? ""
                if let name, let index = pendingIndex {
                    series.append(AO3MetadataRecord.SeriesEntry(
                        name: name,
                        index: index,
                        ao3ID: firstMatch(in: href, pattern: #"/series/([0-9]+)"#)
                    ))
                }
                pendingIndex = nil
            }
        }
        return series
    }

    private static func firstHrefMatching(in doc: Document, pattern: String) throws -> (href: String?, match: String?) {
        for link in try doc.select("a[href]").array() {
            let href = try link.attr("href")
            if let match = firstMatch(in: href, pattern: pattern) {
                return (href, match)
            }
        }
        return (nil, nil)
    }

    private static func firstMatch(in string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }

    private static func absoluteAO3URL(_ href: String) -> String {
        href.hasPrefix("http") ? href : "https://archiveofourown.org\(href)"
    }

    private static func logMissingParsedFieldsIfNeeded(_ record: AO3MetadataRecord) {
        #if DEBUG
        var missing: [String] = []
        if record.wordCount == nil { missing.append("words") }
        if record.chapterCurrent == nil { missing.append("chapter current") }
        guard !missing.isEmpty else { return }
        print("[AO3MetadataExtractor] Parsed AO3 metadata with nil fields missing=\(missing.joined(separator: ", ")) workID=\(record.workID ?? "nil") storyURL=\(record.storyURL ?? "nil") words=\(record.wordCount.map(String.init) ?? "nil") chapterCurrent=\(record.chapterCurrent.map(String.init) ?? "nil") chapterTotal=\(record.chapterTotal.map(String.init) ?? "nil") published=\(record.publishedDate ?? "nil") updated=\(record.updatedDate ?? "nil") extractedAt=\(record.extractedAt)")
        #endif
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
