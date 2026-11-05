// FanfictionFrontmatterParsers.swift
// Dedicated SwiftSoup-based parsers for external fanfiction EPUB generators (FanFicFare, FicLab, FicHub).

import Foundation
import SwiftSoup

enum FanfictionGeneratorFormat: String, Sendable {
    case nativeAO3 = "Native AO3"
    case fanFicFare = "FanFicFare"
    case ficLab = "FicLab"
    case ficHub = "FicHub"
}

enum FanfictionParseResult: Sendable {
    case ao3(AO3MetadataRecord)
    case nonAO3Source(generator: FanfictionGeneratorFormat, archive: String)
}

// MARK: - FanFicFare Parser

enum FanFicFareParser {
    static func canParse(document doc: Document) -> Bool {
        if (try? doc.select("body.fff_titlepage").first()) != nil { return true }
        if let title = try? doc.title(), title.contains("FanFicFare") { return true }
        if (try? doc.select("table.fff_table").first()) != nil { return true }
        return false
    }

    static func parse(document doc: Document) -> FanfictionParseResult? {
        guard canParse(document: doc) else { return nil }

        // Find work link / source
        let links = (try? doc.select("a[href]").array()) ?? []
        var storyHref: String?
        for link in links {
            guard let href = try? link.attr("href") else { continue }
            if href.contains("/works/") || href.contains("archiveofourown.org") {
                storyHref = href
                break
            }
            if href.contains("fanfiction.net/s/") {
                return .nonAO3Source(generator: .fanFicFare, archive: "fanfiction.net")
            }
            if href.contains("fimfiction.net/story/") {
                return .nonAO3Source(generator: .fanFicFare, archive: "fimfiction.net")
            }
        }

        guard let href = storyHref, href.contains("archiveofourown.org/works/") || href.contains("/works/") else {
            return nil
        }

        let workID = firstMatch(in: href, pattern: #"/works/([0-9]+)"#)
        let storyURL = href.hasPrefix("http") ? href : "https://archiveofourown.org\(href)"

        var authors: [AO3AuthorEntry] = []
        let authorLinks = (try? doc.select("a.authorlink, a[href*='/users/']").array()) ?? []
        for aLink in authorLinks {
            guard let name = try? aLink.text().trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let profile = try? aLink.attr("href")
            authors.append(AO3AuthorEntry(
                username: name,
                pseud: nil,
                profileURL: profile.flatMap { $0.hasPrefix("http") ? $0 : "https://archiveofourown.org\($0)" },
                source: .byline
            ))
        }

        var series: [AO3MetadataRecord.SeriesEntry] = []
        let seriesLinks = (try? doc.select("a.serieslink, a[href*='/series/']").array()) ?? []
        for sLink in seriesLinks {
            guard let rawText = try? sLink.text().trimmingCharacters(in: .whitespacesAndNewlines), !rawText.isEmpty else { continue }
            let sHref = (try? sLink.attr("href")) ?? ""
            let seriesID = firstMatch(in: sHref, pattern: #"/series/([0-9]+)"#)
            // Parse "Series Name [1]" or "Part 1 of Series Name"
            if let indexStr = firstMatch(in: rawText, pattern: #"\[([0-9]+)\]"#), let idx = Int(indexStr) {
                let name = rawText.replacingOccurrences(of: "[\(indexStr)]", with: "").trimmingCharacters(in: .whitespaces)
                series.append(AO3MetadataRecord.SeriesEntry(name: name, index: idx, ao3ID: seriesID))
            } else {
                series.append(AO3MetadataRecord.SeriesEntry(name: rawText, index: 1, ao3ID: seriesID))
            }
        }

        // Parse key-value runs: <b>Key:</b> Value
        var rating: String?
        var warnings: [String] = []
        let categories: [String] = []
        var fandoms: [String] = []
        var relationships: [String] = []
        var characters: [String] = []
        var additionalTags: [String] = []
        var publishedDate: String?
        var updatedDate: String?
        var wordCount: Int?
        var chapterCurrent: Int?
        var chapterTotal: Int?
        var isComplete = false

        if let boldElements = try? doc.select("b").array() {
            for boldNode in boldElements {
                guard let key = try? boldNode.text().trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                let normalizedKey = key.replacingOccurrences(of: ":", with: "").lowercased()

                var siblingValues: [String] = []
                var nextSibling = boldNode.nextSibling()
                while let currentSibling = nextSibling {
                    if let elem = currentSibling as? Element, elem.tagName().lowercased() == "br" || elem.tagName().lowercased() == "b" {
                        break
                    }
                    if let textNode = currentSibling as? TextNode {
                        let text = textNode.text().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { siblingValues.append(text) }
                    } else if let elem = currentSibling as? Element {
                        let text = (try? elem.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !text.isEmpty { siblingValues.append(text) }
                    }
                    nextSibling = currentSibling.nextSibling()
                }
                let valueStr = siblingValues.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !valueStr.isEmpty else { continue }

                switch normalizedKey {
                case "rating":
                    rating = valueStr
                case "warnings", "warning":
                    warnings = parseList(valueStr)
                case "category", "fandom", "fandoms":
                    fandoms = parseList(valueStr)
                case "relationships", "relationship":
                    relationships = parseList(valueStr)
                case "characters", "character":
                    characters = parseList(valueStr)
                case "genre", "genres", "tags", "additional tags":
                    additionalTags = parseList(valueStr)
                case "published":
                    publishedDate = valueStr
                case "updated":
                    updatedDate = valueStr
                case "status":
                    isComplete = valueStr.lowercased().contains("complete")
                case "words":
                    let cleaned = valueStr.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                    wordCount = Int(cleaned)
                case "chapters":
                    let parts = valueStr.split(separator: "/")
                    if let first = parts.first, let cur = Int(first.trimmingCharacters(in: .whitespaces)) {
                        chapterCurrent = cur
                        if parts.count > 1, let tot = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                            chapterTotal = tot
                        }
                    } else if let single = Int(valueStr.trimmingCharacters(in: .whitespaces)) {
                        chapterCurrent = single
                    }
                default:
                    break
                }
            }
        }

        let record = AO3MetadataRecord(
            storyURL: storyURL,
            workID: workID,
            authors: authors,
            kudosCount: nil,
            wordCount: wordCount,
            chapterCurrent: chapterCurrent ?? 1,
            chapterTotal: chapterTotal,
            isComplete: isComplete,
            language: nil,
            publishedDate: publishedDate,
            updatedDate: updatedDate,
            fandoms: fandoms,
            relationships: relationships,
            characters: characters,
            additionalTags: additionalTags,
            categories: categories,
            ao3Collections: [],
            series: series,
            rating: rating,
            warnings: warnings,
            extractedAt: ISO8601DateFormatter().string(from: Date())
        )
        return .ao3(record)
    }
}

// MARK: - FicLab Parser

enum FicLabParser {
    static func canParse(document doc: Document) -> Bool {
        if (try? doc.select("body.fl-summary, table.fl-metadata, div.fl-frontmatter").first()) != nil { return true }
        if (try? doc.select("table tr th:contains(author)").first()) != nil &&
           (try? doc.select("table tr th:contains(source)").first()) != nil {
            return true
        }
        return false
    }

    static func parse(document doc: Document) -> FanfictionParseResult? {
        guard canParse(document: doc) else { return nil }

        let links = (try? doc.select("table tr td a[href]").array()) ?? []
        var storyHref: String?
        for link in links {
            guard let href = try? link.attr("href") else { continue }
            if href.contains("/works/") || href.contains("archiveofourown.org") {
                storyHref = href
                break
            }
            if href.contains("fanfiction.net/s/") {
                return .nonAO3Source(generator: .ficLab, archive: "fanfiction.net")
            }
            if href.contains("fimfiction.net/story/") {
                return .nonAO3Source(generator: .ficLab, archive: "fimfiction.net")
            }
        }

        guard let href = storyHref, href.contains("archiveofourown.org/works/") || href.contains("/works/") else {
            return nil
        }

        let workID = firstMatch(in: href, pattern: #"/works/([0-9]+)"#)
        let storyURL = href.hasPrefix("http") ? href : "https://archiveofourown.org\(href)"

        var authors: [AO3AuthorEntry] = []
        var rating: String?
        let fandoms: [String] = []
        var relationships: [String] = []
        var additionalTags: [String] = []
        var publishedDate: String?
        var updatedDate: String?
        var wordCount: Int?
        var chapterCurrent: Int?
        var chapterTotal: Int?
        var isComplete = false

        if let rows = try? doc.select("table tr").array() {
            for row in rows {
                guard let th = try? row.select("th").text().lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                      let td = try? row.select("td").text().trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                switch th {
                case "author":
                    authors.append(AO3AuthorEntry(username: td, pseud: nil, profileURL: nil, source: .byline))
                case "published":
                    publishedDate = td
                case "updated":
                    updatedDate = td
                case "words":
                    let cleaned = td.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                    wordCount = Int(cleaned)
                case "chapters":
                    let parts = td.split(separator: "/")
                    if let first = parts.first, let cur = Int(first.trimmingCharacters(in: .whitespaces)) {
                        chapterCurrent = cur
                        if parts.count > 1, let tot = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                            chapterTotal = tot
                        }
                    } else if let single = Int(td.trimmingCharacters(in: .whitespaces)) {
                        chapterCurrent = single
                    }
                case "status":
                    isComplete = td.lowercased().contains("complete")
                case "rating":
                    rating = td
                case "tags":
                    let tags = parseList(td)
                    for tag in tags {
                        if tag.contains("/") || tag.contains(" & ") {
                            relationships.append(tag)
                        } else {
                            additionalTags.append(tag)
                        }
                    }
                default:
                    break
                }
            }
        }

        let record = AO3MetadataRecord(
            storyURL: storyURL,
            workID: workID,
            authors: authors,
            kudosCount: nil,
            wordCount: wordCount,
            chapterCurrent: chapterCurrent ?? 1,
            chapterTotal: chapterTotal,
            isComplete: isComplete,
            language: nil,
            publishedDate: publishedDate,
            updatedDate: updatedDate,
            fandoms: fandoms,
            relationships: relationships,
            characters: [],
            additionalTags: additionalTags,
            categories: [],
            ao3Collections: [],
            series: [],
            rating: rating,
            warnings: [],
            extractedAt: ISO8601DateFormatter().string(from: Date())
        )
        return .ao3(record)
    }
}

// MARK: - FicHub Parser

enum FicHubParser {
    static func canParse(document doc: Document) -> Bool {
        if (try? doc.select("a[href*='fichub.net']").first()) != nil { return true }
        if (try? doc.select("p:contains(Original source:)").first()) != nil { return true }
        return false
    }

    static func parse(document doc: Document) -> FanfictionParseResult? {
        guard canParse(document: doc) else { return nil }

        let sourceLinks = (try? doc.select("a[href]").array()) ?? []
        var storyHref: String?
        for link in sourceLinks {
            guard let href = try? link.attr("href") else { continue }
            if href.contains("/works/") || href.contains("archiveofourown.org") {
                storyHref = href
                break
            }
            if href.contains("fanfiction.net/s/") {
                return .nonAO3Source(generator: .ficHub, archive: "fanfiction.net")
            }
            if href.contains("fimfiction.net/story/") {
                return .nonAO3Source(generator: .ficHub, archive: "fimfiction.net")
            }
        }

        guard let href = storyHref, href.contains("archiveofourown.org/works/") || href.contains("/works/") else {
            return nil
        }

        let workID = firstMatch(in: href, pattern: #"/works/([0-9]+)"#)
        let storyURL = href.hasPrefix("http") ? href : "https://archiveofourown.org\(href)"

        var authors: [AO3AuthorEntry] = []
        if let authorP = try? doc.select("p:contains(By:)").first()?.text() {
            let name = authorP.replacingOccurrences(of: "By:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                authors.append(AO3AuthorEntry(username: name, pseud: nil, profileURL: nil, source: .byline))
            }
        }

        var publishedDate: String?
        var updatedDate: String?
        var wordCount: Int?
        var isComplete = false

        if let paragraphs = try? doc.select("p").array() {
            for para in paragraphs {
                guard let text = try? para.text().trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                let lower = text.lowercased()
                if lower.hasPrefix("published:") {
                    publishedDate = text.replacingOccurrences(of: "Published:", with: "").trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("updated:") {
                    updatedDate = text.replacingOccurrences(of: "Updated:", with: "").trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("status:") {
                    isComplete = lower.contains("complete")
                } else if lower.hasPrefix("words:") {
                    let cleaned = text.replacingOccurrences(of: "Words:", with: "")
                        .replacingOccurrences(of: ",", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    wordCount = Int(cleaned)
                }
            }
        }

        let record = AO3MetadataRecord(
            storyURL: storyURL,
            workID: workID,
            authors: authors,
            kudosCount: nil,
            wordCount: wordCount,
            chapterCurrent: 1,
            chapterTotal: nil,
            isComplete: isComplete,
            language: nil,
            publishedDate: publishedDate,
            updatedDate: updatedDate,
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
        return .ao3(record)
    }
}

// MARK: - Internal Helpers

private func parseList(_ raw: String) -> [String] {
    raw.components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func firstMatch(in string: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = string as NSString
    guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
          match.numberOfRanges > 1 else { return nil }
    return ns.substring(with: match.range(at: 1))
}
