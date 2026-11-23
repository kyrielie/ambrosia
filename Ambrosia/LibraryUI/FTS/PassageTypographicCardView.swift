// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

// MARK: - Passage Typographic Card View

/// A specialized typographic result card for semantic passage search.
/// Displays similarity confidence, AO3 metadata, and streamed paragraph context.
struct PassageTypographicCardView: View {
    let book: CalibreBook
    let ao3Metadata: AO3MetadataRecord?
    let passage: SemanticPassageMatch
    var isReadLater: Bool = false
    var onToggleReadLater: (() -> Void)?
    let onOpenBook: () -> Void
    let onSelectInLibrary: () -> Void
    let onJumpToPassage: (SemanticPassageMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            metadataBadgesSection
            passageSnippetSection
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
            onJumpToPassage(passage)
        }
        .contextMenu {
            if let onToggleReadLater {
                Button(isReadLater ? "Remove from Read Later" : "Add to Read Later") {
                    onToggleReadLater()
                }
            }
            Button("Jump to Scene") {
                onJumpToPassage(passage)
            }
            Button("Open in Reader") {
                onOpenBook()
            }
            Button("Show in Library") {
                onSelectInLibrary()
            }
            Divider()
            Button("Copy Scene Excerpt") {
                copySceneExcerpt()
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(book.displayTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .onTapGesture(perform: onOpenBook)

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

            similarityBadge(percentage: passage.similarityPercentage)
        }
    }

    // MARK: - Similarity Badge

    private func similarityBadge(percentage: Int) -> some View {
        let label = "\(percentage)% Match"
        let badgeColor: Color = percentage >= 85 ? .green : (percentage >= 70 ? .accentColor : .secondary)

        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(badgeColor.opacity(0.14))
            )
            .foregroundColor(badgeColor)
    }

    // MARK: - Metadata Badges Section

    private var metadataBadgesSection: some View {
        HStack(spacing: 6) {
            ratingBadge

            let fandoms = ao3Metadata?.fandoms ?? []
            ForEach(fandoms.prefix(2), id: \.self) { fandom in
                badgePill(label: fandom, color: .purple)
            }

            if let relationship = ao3Metadata?.relationships.first, !relationship.isEmpty {
                badgePill(label: relationship, color: .pink, isItalic: true)
            }

            let wordCount = ao3Metadata?.wordCount ?? book.wordCount
            if let count = wordCount, count > 0 {
                badgePill(label: WordCountFormatting.label(count), color: .secondary)
            }

            if let ao3 = ao3Metadata {
                let statusLabel = ao3.isComplete ? "✓ Complete" : "In Progress"
                let statusColor = ao3.isComplete ? Color.green : Color.secondary
                badgePill(label: statusLabel, color: statusColor)
            }

            Spacer(minLength: 0)
        }
    }

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

    private func badgePill(label: String, color: Color, isItalic: Bool = false) -> some View {
        let text = Text(label).font(.caption2)
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

    // MARK: - Passage Snippet Section

    private var passageSnippetSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let text = passage.extractedText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: 6) {
                        Text(passage.anchorPhrase)
                            .font(.system(size: 12).italic())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        if passage.isLoadingText {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }

            Button {
                onJumpToPassage(passage)
            } label: {
                HStack(spacing: 4) {
                    Text("Jump to Scene")
                    Image(systemName: "arrow.up.forward.app")
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 2)
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

    private func copySceneExcerpt() {
        var lines: [String] = []
        lines.append("\(book.displayTitle) by \(book.displayAuthors)")
        if let series = book.displaySeries {
            lines.append("Series: \(series)")
        }
        lines.append("Match: \(passage.similarityPercentage)%")
        lines.append("")
        let content = passage.extractedText ?? passage.anchorPhrase
        lines.append("\"\(content)\"")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
