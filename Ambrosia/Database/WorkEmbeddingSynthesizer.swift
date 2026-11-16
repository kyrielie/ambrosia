// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Constructs high-signal, normalized text documents for story-level vector embeddings.
enum WorkEmbeddingSynthesizer {
    static let summaryLimit = 600

    static func synthesize(book: CalibreBook, ao3: AO3MetadataRecord?, summary: String? = nil) -> String {
        var lines: [String] = []

        if !book.title.isEmpty {
            lines.append("Title: \(book.title)")
        }
        if !book.authors.isEmpty {
            lines.append("Author: \(book.authors.joined(separator: ", "))")
        }
        if let series = book.series, !series.isEmpty {
            lines.append("Series: \(series)")
        }
        if let ao3 {
            if !ao3.fandoms.isEmpty {
                lines.append("Fandom: \(ao3.fandoms.joined(separator: ", "))")
            }
            if !ao3.relationships.isEmpty {
                lines.append("Relationships: \(ao3.relationships.joined(separator: ", "))")
            }
            if !ao3.characters.isEmpty {
                lines.append("Characters: \(ao3.characters.joined(separator: ", "))")
            }
            if !ao3.additionalTags.isEmpty {
                lines.append("Tags: \(ao3.additionalTags.joined(separator: ", "))")
            }
            if let rating = ao3.rating, !rating.isEmpty {
                lines.append("Rating: \(rating)")
            }
            if let language = ao3.language, !language.isEmpty {
                lines.append("Language: \(language)")
            }
            lines.append("Status: \(ao3.isComplete ? "Complete" : "Work in Progress")")
        } else if !book.tags.isEmpty {
            lines.append("Tags: \(book.tags.joined(separator: ", "))")
        }

        let effectiveSummary = summary ?? book.displayComment
        if let effectiveSummary, !effectiveSummary.isEmpty {
            let stripped = HTMLStripper.strip(effectiveSummary).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                lines.append("Summary: \(stripped.prefix(summaryLimit))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
