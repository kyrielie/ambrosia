import SwiftUI

// MARK: - FlowLayout
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    struct Cache {
        var subviewSizes: [CGSize] = []
        var lastWidth: CGFloat = -1
        var rows: [(startIndex: Int, y: CGFloat, height: CGFloat)] = []
        var totalHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        var c = Cache()
        c.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return c
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.lastWidth = -1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? 800
        refreshSubviewSizes(in: &cache, subviews: subviews)
        rebuildRows(in: &cache, maxWidth: maxWidth)
        return CGSize(width: maxWidth, height: cache.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        refreshSubviewSizes(in: &cache, subviews: subviews)
        rebuildRows(in: &cache, maxWidth: bounds.width)
        var rowIdx = 0
        var x = bounds.minX

        for (i, sub) in subviews.enumerated() {
            let size = cache.subviewSizes[i]
            if rowIdx + 1 < cache.rows.count && i >= cache.rows[rowIdx + 1].startIndex {
                rowIdx += 1
                x = bounds.minX
            }
            let currentRowY = bounds.minY + cache.rows[rowIdx].y
            let currentRowH = cache.rows[rowIdx].height
            let yOffset = (currentRowH - size.height) / 2
            sub.place(at: CGPoint(x: x, y: currentRowY + yOffset), proposal: .unspecified)
            x += size.width + spacing
        }
    }

    private func refreshSubviewSizes(in cache: inout Cache, subviews: Subviews) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if sizes != cache.subviewSizes {
            cache.subviewSizes = sizes
            cache.lastWidth = -1
        }
    }

    private func rebuildRows(in cache: inout Cache, maxWidth: CGFloat) {
        guard abs(cache.lastWidth - maxWidth) > 0.5 else { return }
        cache.lastWidth = maxWidth

        var rows: [(startIndex: Int, y: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var rowStart = 0

        for (i, size) in cache.subviewSizes.enumerated() {
            if x + size.width > maxWidth && x > 0 {
                rows.append((startIndex: rowStart, y: y, height: rowH))
                y += rowH + spacing
                x = 0; rowH = 0; rowStart = i
            }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        rows.append((startIndex: rowStart, y: y, height: rowH))
        cache.rows = rows
        cache.totalHeight = y + rowH
    }
}

func isAnthology(_ book: CalibreBook) -> Bool {
    book.isDescriptionAnthology
}

func missingIndices(in indices: [Int]) -> [Int] {
    let unique = Array(Set(indices)).sorted()
    guard let last = unique.last, last > 1 else { return [] }
    let present = Set(unique)
    return (1...last).filter { !present.contains($0) }
}

func parseISODate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
}

func logMissingVisibleWorkMetadata(
    book: CalibreBook,
    ao3Metadata: AO3MetadataRecord?,
    diagnostic: AO3ExtractionDiagnostic?
) {
    #if DEBUG
    let missingWords = (ao3Metadata?.wordCount ?? book.wordCount) == nil
    let missingChapters = ao3Metadata?.chapterCurrent == nil
    guard missingWords || missingChapters else { return }

    var reasons: [String] = []
    if ao3Metadata == nil {
        if let diagnostic {
            reasons.append("no AO3 metadata row; extractionStatus=\(diagnostic.status); extractionReason=\(diagnostic.reason)")
        } else {
            reasons.append("no AO3 metadata row; extraction has not recorded a status yet (pending, not attempted under diagnostics schema, or pre-diagnostics DB)")
        }
    } else {
        if ao3Metadata?.wordCount == nil {
            reasons.append("AO3 metadata has nil word count")
        }
        if ao3Metadata?.chapterCurrent == nil {
            reasons.append("AO3 metadata has nil chapter current")
        }
    }
    if missingWords, book.wordCount == nil {
        reasons.append("Calibre fallback missing")
    }

    print("[LibraryMetadata] visible work missing displayed metadata reason=\(reasons.joined(separator: "; ")) calibreID=\(book.id) title=\"\(book.displayTitle)\" hasAO3Metadata=\(ao3Metadata != nil) ao3WorkID=\(ao3Metadata?.workID ?? "nil") ao3Words=\(ao3Metadata?.wordCount.map(String.init) ?? "nil") ao3ChapterCurrent=\(ao3Metadata?.chapterCurrent.map(String.init) ?? "nil") ao3ChapterTotal=\(ao3Metadata?.chapterTotal.map(String.init) ?? "nil") calibreWords=\(book.wordCount.map(String.init) ?? "nil") extractedAt=\(ao3Metadata?.extractedAt ?? "nil") extractionStatus=\(diagnostic?.status ?? "nil") extractionReason=\"\(diagnostic?.reason ?? "nil")\" attemptedAt=\(diagnostic?.attemptedAt ?? "nil") epubFilename=\"\(diagnostic?.epubFilename ?? "nil")\" epubPath=\"\(diagnostic?.epubPath ?? "nil")\" spineItemsChecked=\(diagnostic?.spineItemsChecked.map(String.init) ?? "nil")")
    #endif
}

