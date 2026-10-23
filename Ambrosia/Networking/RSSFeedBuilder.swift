import Foundation

enum RSSFeedBuilder {
    static let calibrePubdateSentinel = Date(timeIntervalSince1970: 0)

    static func buildFeed(
        title: String,
        feedDescription: String,
        items: [String],
        buildDate: Date = Date()
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:ambrosia="https://ambrosia.app/rss-extension">
          <channel>
            <title>\(xmlEscape(title))</title>
            <description>\(xmlEscape(feedDescription))</description>
            <generator>Ambrosia</generator>
            <lastBuildDate>\(FeedDateFormatter.rfc822Date(from: buildDate))</lastBuildDate>
            \(items.joined(separator: "\n    "))
          </channel>
        </rss>
        """
    }

    static func buildEmptyFeed(title: String, message: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>\(xmlEscape(title))</title>
            <description>\(xmlEscape(message))</description>
          </channel>
        </rss>
        """
    }

    static func buildRSSItem(
        book: CalibreBook,
        ao3: AO3MetadataRecord?,
        seriesEntries: [SeriesCacheEntry],
        contentEncoded: String
    ) -> String {
        let strippedComment = book.comment.map { HTMLStripper.strip($0) } ?? ""
        let statsLine = buildStatsLine(book: book, ao3: ao3)
        let description = [strippedComment, statsLine]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let pubDateStr: String
        if let ao3Date = ao3?.publishedDate, !ao3Date.isEmpty {
            pubDateStr = FeedDateFormatter.rfc822Date(from: ao3Date)
        } else if let calibreDate = book.publishedDate,
                  calibreDate > calibrePubdateSentinel {
            pubDateStr = FeedDateFormatter.rfc822Date(from: calibreDate)
        } else {
            pubDateStr = ""
        }

        var xml = """
            <item>
              <title>\(xmlEscape(book.displayTitle))</title>
              <guid isPermaLink="false">ambrosia-book-\(book.id)</guid>
        """
        if let workURL = ao3?.storyURL {
            xml += "\n      <link>\(xmlEscape(workURL))</link>"
        }
        xml += "\n      <description>\(xmlEscape(description))</description>"
        if !book.authors.isEmpty {
            xml += "\n      <author>\(xmlEscape(book.authors.joined(separator: ", ")))</author>"
        }
        if !pubDateStr.isEmpty {
            xml += "\n      <pubDate>\(pubDateStr)</pubDate>"
        }
        if !contentEncoded.isEmpty {
            xml += "\n      <content:encoded><![CDATA[\(contentEncoded)]]></content:encoded>"
        }
        if let workID = ao3?.workID, !workID.isEmpty {
            xml += "\n      <ambrosia:workID>\(xmlEscape(workID))</ambrosia:workID>"
        }
        if let anthologyEntry = anthologySeriesEntry(for: book, seriesEntries: seriesEntries) {
            xml += "\n      <ambrosia:isAnthology>true</ambrosia:isAnthology>"
            if let seriesID = anthologyEntry.ao3SeriesID, !seriesID.isEmpty {
                xml += "\n      <ambrosia:ao3SeriesID>\(xmlEscape(seriesID))</ambrosia:ao3SeriesID>"
            } else {
                xml += "\n      <ambrosia:seriesName>\(xmlEscape(anthologyEntry.seriesName))</ambrosia:seriesName>"
            }
        }
        xml += "\n    </item>"
        return xml
    }

    static func buildGroupedRSSItem(
        group: SeriesGroup,
        members: [FeedBookPair],
        memberHTMLs: [String]
    ) -> String {
        let contentEncoded = memberHTMLs.joined(separator: "\n<hr/>\n")
        let description = group.allDescriptions.joined(separator: "\n\n")

        var xml = """
            <item>
              <title>\(xmlEscape(group.seriesName))</title>
              <guid isPermaLink="false">ambrosia-series-\(group.seriesKey)</guid>
        """
        let leaderAO3 = members.first?.ao3
        let link: String?
        if group.seriesKey.hasPrefix("ao3:") {
            link = "https://archiveofourown.org/series/\(group.seriesKey.dropFirst("ao3:".count))"
        } else {
            link = leaderAO3?.storyURL
        }
        if let link {
            xml += "\n      <link>\(xmlEscape(link))</link>"
        }
        xml += "\n      <description>\(xmlEscape(description))</description>"
        if !group.allAuthors.isEmpty {
            xml += "\n      <author>\(xmlEscape(group.allAuthors.joined(separator: ", ")))</author>"
        }
        if let latest = group.latestUpdated {
            xml += "\n      <pubDate>\(FeedDateFormatter.rfc822Date(from: latest))</pubDate>"
        }
        if !contentEncoded.isEmpty {
            xml += "\n      <content:encoded><![CDATA[\(contentEncoded)]]></content:encoded>"
        }
        xml += "\n    </item>"
        return xml
    }

    static func buildStatsLine(book: CalibreBook, ao3: AO3MetadataRecord?) -> String {
        var parts: [String] = []
        if let wordCount = ao3?.wordCount ?? book.wordCount, wordCount > 0 {
            parts.append(book.displayWordCount)
        }
        if let fandoms = ao3?.fandoms, !fandoms.isEmpty {
            parts.append(fandoms.prefix(3).joined(separator: ", "))
        }
        if let ao3 {
            let status = ao3.isComplete
                ? AO3CompletionStatus.complete.rawValue
                : AO3CompletionStatus.workInProgress.rawValue
            parts.append(status)
        }
        return parts.joined(separator: " · ")
    }
}
