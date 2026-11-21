// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// MARK: - Passage Snippet Extractor

/// Extracts narrative passage text directly from local EPUB spine items using UTF-16 code unit offsets.
public enum PassageSnippetExtractor {

    /// Reads the plain text of a specific spine item in an EPUB and slices the passage range.
    public static func extractPassage(
        epubURL: URL,
        spineIndex: Int,
        startOffset: Int,
        endOffset: Int
    ) -> String? {
        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            return nil
        }

        var parser = EPUBParser(epubURL: epubURL)
        do {
            try parser.parse(skipTOC: true)
            guard spineIndex >= 0, spineIndex < parser.spine.count else {
                return nil
            }
            let item = parser.spine[spineIndex]
            let fullText = try parser.plainText(for: item)
            let utf16 = fullText.utf16
            let totalLen = utf16.count

            guard startOffset < totalLen else { return nil }

            let safeStart = max(0, min(startOffset, totalLen))
            let safeEnd = max(safeStart, min(endOffset, totalLen))

            let startIdx = utf16.index(utf16.startIndex, offsetBy: safeStart)
            let endIdx = utf16.index(utf16.startIndex, offsetBy: safeEnd)

            guard let substring = String(utf16[startIdx..<endIdx]) else {
                return nil
            }
            return substring.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
