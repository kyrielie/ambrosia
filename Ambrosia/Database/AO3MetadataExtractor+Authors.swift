import Foundation
import SwiftSoup

// MARK: - AO3MetadataExtractor+Authors
//
// Author parsing lives in its own file, separate from the preface `dl.tags`
// parsing in AO3MetadataExtractor.swift, because it operates on a different
// spine item's HTML entirely: the preface (split_000) never contains author
// markup, but the *next* chapter spine item (split_001) does, inside
// `div.byline`, immediately after the chapter's `<h1>`. See the byline shape
// notes in the Part 2 implementation plan for the empirical basis.

extension AO3MetadataExtractor {
    /// Parses AO3 author entries from a chapter spine item's byline HTML.
    /// Returns an empty array if no byline is present, so callers can treat
    /// "not found on this spine item" and "found but empty" identically.
    static func parseAuthors(from html: String) -> [AO3AuthorEntry] {
        guard let doc = try? SwiftSoup.parse(html),
              let byline = try? doc.select("div.byline").first()
        else { return [] }

        guard let authorLinks = try? byline.select("a[rel=author]"), !authorLinks.isEmpty() else {
            // "by Anonymous" (or any other future plain-text case) — no <a> at all.
            let text = ((try? byline.text()) ?? "").replacingOccurrences(of: "by ", with: "")
            guard !text.isEmpty else { return [] }
            if text == "Anonymous" {
                // Anonymous has no derivable profile URL from any href — it's a
                // fixed AO3 URL (the Anonymous Collection), conceptually
                // different from a user profile.
                return [AO3AuthorEntry(
                    username: "Anonymous", pseud: nil,
                    profileURL: "https://archiveofourown.org/collections/anonymous",
                    source: .byline
                )]
            }
            return [AO3AuthorEntry(username: text, pseud: nil, profileURL: nil, source: .byline)]
        }

        return authorLinks.array().compactMap { link -> AO3AuthorEntry? in
            guard let href = try? link.attr("href") else { return nil }
            // href always has both /users/USERNAME/ and /pseuds/PSEUD segments,
            // even when identical (orphan_account/pseuds/orphan_account) — the
            // href is authoritative, never infer username/pseud from link text.
            guard let usersRange = href.range(of: "/users/") else { return nil }
            let afterUsers = href[usersRange.upperBound...]
            let username = afterUsers.components(separatedBy: "/pseuds/").first ?? ""
            let pseudRaw = afterUsers.components(separatedBy: "/pseuds/").last
            let pseud = (pseudRaw == username || pseudRaw?.isEmpty != false) ? nil : pseudRaw
            guard !username.isEmpty else { return nil }
            // Normalise http:// -> https://, matching the existing story_url
            // normalisation rule in extract().
            let profileURL = ("https://archiveofourown.org/users/\(username)/"
                + (pseud != nil ? "pseuds/\(pseud!)" : ""))
                .replacingOccurrences(of: "http://", with: "https://")
            return AO3AuthorEntry(username: username, pseud: pseud, profileURL: profileURL, source: .byline)
        }
    }
}
