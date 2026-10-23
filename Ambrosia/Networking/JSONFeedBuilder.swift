import Foundation

// MARK: - JSON Feed 1.1 model types

struct JSONFeedAuthor: Codable, Equatable {
    var name: String?
    var url: String?
}

struct JSONFeedSeriesEntry: Codable, Equatable {
    var name: String
    var index: Int
    var ao3ID: String?

    enum CodingKeys: String, CodingKey {
        case name, index
        case ao3ID = "ao3_id"
    }
}

/// Ambrosia-specific metadata that has no JSON Feed 1.1 field of its own.
struct JSONFeedAmbrosiaExtension: Codable, Equatable {
    var wordCount: Int?
    var chapterCurrent: Int?
    var chapterTotal: Int?
    var isComplete: Bool?
    var fandoms: [String]?
    var relationships: [String]?
    var characters: [String]?
    var ratings: [String]?
    var warnings: [String]?
    var categories: [String]?
    var series: [JSONFeedSeriesEntry]?
    var dateModified: String?
    var ao3WorkID: String?
    var isAnthology: Bool?
    var ao3SeriesID: String?
    var seriesName: String?

    enum CodingKeys: String, CodingKey {
        case wordCount = "word_count"
        case chapterCurrent = "chapter_current"
        case chapterTotal = "chapter_total"
        case isComplete = "is_complete"
        case fandoms, relationships, characters, ratings, warnings, categories, series
        case dateModified = "date_modified"
        case ao3WorkID = "ao3_work_id"
        case isAnthology = "is_anthology"
        case ao3SeriesID = "ao3_series_id"
        case seriesName = "series_name"
    }
}

struct JSONFeedItem: Codable, Equatable {
    var id: String
    var url: String?
    var title: String?
    var contentHTML: String?
    var summary: String?
    var datePublished: String?
    var authors: [JSONFeedAuthor]?
    var tags: [String]?
    var ambrosiaExtension: JSONFeedAmbrosiaExtension?

    enum CodingKeys: String, CodingKey {
        case id, url, title, summary, authors, tags
        case contentHTML = "content_html"
        case datePublished = "date_published"
        case ambrosiaExtension = "_ambrosia"
    }
}

struct JSONFeedDocument: Codable, Equatable {
    var version = "https://jsonfeed.org/version/1.1"
    var title: String
    var description: String?
    var homePageURL: String?
    var feedURL: String?
    var nextURL: String?
    var items: [JSONFeedItem]

    enum CodingKeys: String, CodingKey {
        case version, title, description, items
        case homePageURL = "home_page_url"
        case feedURL = "feed_url"
        case nextURL = "next_url"
    }
}

// MARK: - JSONFeedBuilder

enum JSONFeedBuilder {
    static let calibrePubdateSentinel = Date(timeIntervalSince1970: 0)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    static func buildJSONFeedItem(
        book: CalibreBook,
        ao3: AO3MetadataRecord?,
        seriesEntries: [SeriesCacheEntry],
        contentHTML: String
    ) -> JSONFeedItem {
        let summary = book.comment.map { HTMLStripper.strip($0) } ?? ""

        let datePublished: String?
        if let ao3Date = ao3?.publishedDate, !ao3Date.isEmpty {
            datePublished = FeedDateFormatter.iso8601DateString(from: ao3Date)
        } else if let calibreDate = book.publishedDate,
                  calibreDate > calibrePubdateSentinel {
            datePublished = FeedDateFormatter.iso8601DateString(from: calibreDate)
        } else {
            datePublished = nil
        }

        let authors: [JSONFeedAuthor]? = book.authors.isEmpty ? nil : book.authors.map { name in
            let url = (book.authors.count == 1 && ao3?.authors.count == 1)
                ? ao3?.authors.first?.profileURL : nil
            return JSONFeedAuthor(name: name, url: url)
        }

        let buckets = AO3TagBuckets.from(tags: book.tags)
        var seenTags = Set<String>()
        var tags: [String] = []
        for tag in buckets.regular + (ao3?.additionalTags ?? []) where seenTags.insert(tag).inserted {
            tags.append(tag)
        }

        let fandoms       = dedupPreservingOrder(ao3?.fandoms.compactMap { $0.isEmpty ? nil : $0 } ?? [])
        let relationships = dedupPreservingOrder(ao3?.relationships.compactMap { $0.isEmpty ? nil : $0 } ?? [])
        let characters    = dedupPreservingOrder(ao3?.characters.compactMap { $0.isEmpty ? nil : $0 } ?? [])
        let categories    = dedupPreservingOrder(buckets.categories + (ao3?.categories ?? []))
        let warnings      = dedupPreservingOrder(buckets.warnings)

        let dateModified = ao3?.updatedDate.flatMap { $0.isEmpty ? nil : FeedDateFormatter.iso8601DateString(from: $0) }
        let anthologyEntry = anthologySeriesEntry(for: book, seriesEntries: seriesEntries)

        let ambrosiaExtensionValue = JSONFeedAmbrosiaExtension(
            wordCount: ao3?.wordCount ?? book.wordCount,
            chapterCurrent: ao3?.chapterCurrent,
            chapterTotal: ao3?.chapterTotal,
            isComplete: ao3?.isComplete,
            fandoms: fandoms.isEmpty ? nil : fandoms,
            relationships: relationships.isEmpty ? nil : relationships,
            characters: characters.isEmpty ? nil : characters,
            ratings: AO3Rating.highest(among: book.tags).map { [$0.rawValue] },
            warnings: warnings.isEmpty ? nil : warnings,
            categories: categories.isEmpty ? nil : categories,
            series: ao3?.series.map { JSONFeedSeriesEntry(name: $0.name, index: $0.index, ao3ID: $0.ao3ID) },
            dateModified: dateModified,
            ao3WorkID: ao3?.workID.flatMap { $0.isEmpty ? nil : $0 },
            isAnthology: anthologyEntry != nil ? true : nil,
            ao3SeriesID: anthologyEntry?.ao3SeriesID,
            seriesName: anthologyEntry != nil && (anthologyEntry?.ao3SeriesID?.isEmpty ?? true) ? anthologyEntry?.seriesName : nil
        )

        return JSONFeedItem(
            id: "ambrosia-book-\(book.id)",
            url: ao3?.storyURL,
            title: book.displayTitle,
            contentHTML: contentHTML.isEmpty ? nil : contentHTML,
            summary: summary.isEmpty ? nil : summary,
            datePublished: datePublished,
            authors: authors,
            tags: tags.isEmpty ? nil : tags,
            ambrosiaExtension: ambrosiaExtensionValue
        )
    }

    static func buildGroupedJSONFeedItem(
        group: SeriesGroup,
        members: [FeedBookPair],
        memberHTMLs: [String]
    ) -> JSONFeedItem {
        let contentHTML = memberHTMLs.joined(separator: "\n<hr/>\n")
        let summary = group.allDescriptions.joined(separator: "\n\n")

        let unionTags = members.flatMap { $0.book.tags }
        let buckets = AO3TagBuckets.from(tags: unionTags)
        var seenTags = Set<String>()
        var tags: [String] = []
        for tag in buckets.regular + group.allAdditionalTags where seenTags.insert(tag).inserted {
            tags.append(tag)
        }

        let fandoms       = dedupPreservingOrder(group.allFandoms)
        let relationships = dedupPreservingOrder(group.allRelationships)
        let characters    = dedupPreservingOrder(group.allCharacters)
        let categories    = dedupPreservingOrder(buckets.categories + group.allCategories)
        let warnings      = dedupPreservingOrder(buckets.warnings)

        let ratings = AO3Rating.highest(among: unionTags).map { [$0.rawValue] }

        let leaderAO3 = members.first?.ao3
        let datePublished = group.earliestPublished.map { FeedDateFormatter.iso8601DateString(from: $0) }
        let dateModified = group.latestUpdated.map { FeedDateFormatter.iso8601DateString(from: $0) }

        let authors: [JSONFeedAuthor]? = group.allAuthors.isEmpty ? nil : group.allAuthors.map { name in
            let url = (group.allAuthors.count == 1 && leaderAO3?.authors.count == 1)
                ? leaderAO3?.authors.first?.profileURL : nil
            return JSONFeedAuthor(name: name, url: url)
        }

        let url: String?
        if group.seriesKey.hasPrefix("ao3:") {
            let ao3SeriesID = String(group.seriesKey.dropFirst("ao3:".count))
            url = "https://archiveofourown.org/series/\(ao3SeriesID)"
        } else {
            url = leaderAO3?.storyURL
        }

        let ambrosiaExtensionValue = JSONFeedAmbrosiaExtension(
            wordCount: group.totalWordCount,
            chapterCurrent: group.chapterCurrentTotal,
            chapterTotal: group.chapterTotalTotal,
            isComplete: group.isComplete,
            fandoms: fandoms.isEmpty ? nil : fandoms,
            relationships: relationships.isEmpty ? nil : relationships,
            characters: characters.isEmpty ? nil : characters,
            ratings: ratings,
            warnings: warnings.isEmpty ? nil : warnings,
            categories: categories.isEmpty ? nil : categories,
            series: nil,
            dateModified: dateModified,
            ao3WorkID: nil,
            isAnthology: nil,
            ao3SeriesID: group.seriesKey.hasPrefix("ao3:") ? String(group.seriesKey.dropFirst(4)) : nil,
            seriesName: group.seriesKey.hasPrefix("ao3:") ? nil : group.seriesName
        )

        return JSONFeedItem(
            id: "ambrosia-series-\(group.seriesKey)",
            url: url,
            title: group.seriesName,
            contentHTML: contentHTML.isEmpty ? nil : contentHTML,
            summary: summary.isEmpty ? nil : summary,
            datePublished: datePublished,
            authors: authors,
            tags: tags.isEmpty ? nil : tags,
            ambrosiaExtension: ambrosiaExtensionValue
        )
    }

    static func buildJSONFeedDocument(
        title: String,
        feedDescription: String,
        feedURL: String,
        nextURL: String? = nil,
        items: [JSONFeedItem]
    ) -> JSONFeedDocument {
        JSONFeedDocument(
            title: title,
            description: feedDescription,
            homePageURL: nil,
            feedURL: feedURL,
            nextURL: nextURL,
            items: items
        )
    }

    static func buildEmptyJSONFeed(
        title: String,
        feedDescription: String,
        feedURL: String
    ) -> Data {
        let doc = buildJSONFeedDocument(title: title, feedDescription: feedDescription, feedURL: feedURL, items: [])
        return encode(doc) ?? Data("{}".utf8)
    }

    static func encode(_ document: JSONFeedDocument) -> Data? {
        try? encoder.encode(document)
    }
}
