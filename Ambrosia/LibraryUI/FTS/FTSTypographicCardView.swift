import SwiftUI
import AppKit

// MARK: - FTS Typographic Card View (Track 1 / Option B)

/// A typographic search result card displaying high-signal AO3 metadata badges
/// and up to 5 passage snippets with highlighted search terms.
struct FTSTypographicCardView: View {
    let book: CalibreBook
    let ao3Metadata: AO3MetadataRecord?
    let result: FTSMultiSnippetResult?
    let isLoadingSnippets: Bool
    let onOpen: () -> Void
    let onSelectInLibrary: () -> Void
    let onJumpToSnippet: (FTSOccurrenceSnippet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            metadataBadgesSection
            snippetsSection
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpen()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(book.displayTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .onTapGesture(perform: onOpen)

            if let series = book.displaySeries {
                Text("(\(series))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Text("by \(book.displayAuthors)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let result {
                matchCountBadge(count: result.totalOccurrences)
            } else if isLoadingSnippets {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Rating Badge

    private var ratingBadge: some View {
        let (ratingLabel, ratingColor) = resolvedRating
        return Text(ratingLabel)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(ratingColor.opacity(0.12))
            )
            .foregroundColor(ratingColor)
    }

    private var resolvedRating: (String, Color) {
        let rawRating = ao3Metadata?.rating
        let rating = rawRating.flatMap { AO3Rating(rawValue: $0) }
            ?? AO3Rating.highest(among: book.tags)

        guard let rating else {
            return ("Not Rated", Color.secondary.opacity(0.7))
        }

        switch rating {
        case .explicit:
            return ("Explicit", Color.red)
        case .mature:
            return ("Mature", Color.orange)
        case .teenAndUp:
            return ("Teen And Up", Color.yellow)
        case .generalAudiences:
            return ("General Audiences", Color.green)
        case .notRated:
            return ("Not Rated", Color.secondary.opacity(0.7))
        }
    }

    // MARK: - Match Count Badge

    private func matchCountBadge(count: Int) -> some View {
        let label = count == 1 ? "1 match" : "\(count) matches"
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(0.12))
            )
            .foregroundColor(.accentColor)
    }

    // MARK: - Metadata Badges Section

    private var metadataBadgesSection: some View {
        HStack(spacing: 6) {
            // Rating pill inline with high-signal tags
            ratingBadge

            // High-signal AO3 badges: Fandoms (first 1-2)
            let fandoms = ao3Metadata?.fandoms ?? []
            ForEach(fandoms.prefix(2), id: \.self) { fandom in
                badgePill(label: fandom, color: .purple)
            }

            // Primary Relationship (italicized)
            if let relationship = ao3Metadata?.relationships.first, !relationship.isEmpty {
                badgePill(label: relationship, color: .pink, isItalic: true)
            }

            // Word Count
            let wordCount = ao3Metadata?.wordCount ?? book.wordCount
            if let wc = wordCount, wc > 0 {
                badgePill(label: formatWordCount(wc), color: .secondary)
            }

            // Completion Status
            if let ao3 = ao3Metadata {
                let statusLabel = ao3.isComplete ? "✓ Complete" : "In Progress"
                let statusColor = ao3.isComplete ? Color.green : Color.secondary
                badgePill(label: statusLabel, color: statusColor)
            }

            Spacer(minLength: 0)
        }
    }

    private func badgePill(label: String, color: Color, isItalic: Bool = false) -> some View {
        let text = Text(label)
            .font(.caption2)
        return (isItalic ? text.italic() : text)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.12))
            )
            .foregroundColor(color)
    }

    private func formatWordCount(_ wc: Int) -> String {
        switch wc {
        case 0..<1_000:
            return "\(wc) words"
        case 0..<1_000_000:
            return String(format: "%.1fk words", Double(wc) / 1_000)
        default:
            return String(format: "%.2fM words", Double(wc) / 1_000_000)
        }
    }

    // MARK: - Snippets Section

    @ViewBuilder
    private var snippetsSection: some View {
        if isLoadingSnippets && result == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching book text…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } else if let result, !result.snippets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.snippets) { snippet in
                    snippetRow(snippet)
                }
            }
            .padding(.vertical, 2)
        } else {
            Text("No text passages found.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 2)
        }
    }

    private func snippetRow(_ snippet: FTSOccurrenceSnippet) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Snippet text with highlighted terms
            Text(Self.makeAttributedString(from: snippet.text))
                .font(.system(size: 12))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            // Jump button
            Button {
                onJumpToSnippet(snippet)
            } label: {
                HStack(spacing: 3) {
                    Text("Jump")
                    Image(systemName: "arrow.up.forward.app")
                }
                .font(.caption2.weight(.medium))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.accentColor)
            .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    /// Formats snippets with title and author attribution and writes to the pasteboard.
    private func copyExcerpts() {
        guard let result, !result.snippets.isEmpty else { return }
        var lines: [String] = []
        lines.append("\(book.displayTitle) by \(book.displayAuthors)")
        if let series = book.displaySeries {
            lines.append("Series: \(series)")
        }
        lines.append("")

        for (index, snippet) in result.snippets.enumerated() {
            let cleanText = snippet.text.replacingOccurrences(of: "\u{1D}", with: "")
            let pct = Int(snippet.approximatePercent.rounded())
            lines.append("[\(index + 1)] [\(pct)%] \"\(cleanText)\"")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Converts snippet text containing `\u{1D}` highlight delimiters into an `AttributedString`
    /// where matched terms are bolded and highlighted with the accent color.
    static func makeAttributedString(from text: String, highlightColor: Color = .accentColor) -> AttributedString {
        var attributed = AttributedString()
        let parts = text.components(separatedBy: "\u{1D}")
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty else { continue }
            var sub = AttributedString(part)
            if index % 2 == 1 {
                sub.inlinePresentationIntent = .stronglyEmphasized
                sub.foregroundColor = highlightColor
            }
            attributed.append(sub)
        }
        return attributed
    }
}
