import Foundation

enum OPMLFeedBuilder {
    static func buildOPML(
        collections: [CollectionRow],
        dailyEnabled: Bool,
        searchSnapshot: CurrentSearchSnapshot?,
        baseURL: String
    ) -> String {
        let now = ISO8601DateFormatter().string(from: Date())

        var outlines = collections.map { col in
            """
            <outline type="rss"
                     text="\(xmlEscape(col.name))"
                     title="\(xmlEscape(col.name))"
                     xmlUrl="\(xmlEscape("\(baseURL)/feed/collection/\(col.id).xml"))"/>
            """
        }

        if dailyEnabled {
            outlines.append("""
            <outline type="rss"
                     text="Daily Story"
                     title="Daily Story"
                     xmlUrl="\(xmlEscape("\(baseURL)/feed/random-daily.xml"))"/>
            """)
        }

        if let snapshot = searchSnapshot {
            outlines.append("""
            <outline type="rss"
                     text="\(xmlEscape("Search: \(snapshot.label)"))"
                     title="\(xmlEscape("Search: \(snapshot.label)"))"
                     xmlUrl="\(xmlEscape("\(baseURL)/feed/search.xml"))"/>
            """)
        }

        let body = outlines.isEmpty
            ? "<!-- No collections or search snapshot to export. -->"
            : outlines.joined(separator: "\n    ")

        let docsText = "Feed URLs are tied to this Mac's current local network address and may break if the address "
            + "changes or the server restarts. Re-export from Ambrosia to get updated URLs."
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Ambrosia Library Feeds</title>
            <dateCreated>\(now)</dateCreated>
            <docs>\(docsText)</docs>
          </head>
          <body>
            \(body)
          </body>
        </opml>
        """
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
