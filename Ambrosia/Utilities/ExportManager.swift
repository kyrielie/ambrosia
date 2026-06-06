import Foundation
import AppKit

/// Exports a list of `CalibreBook` structs to a CSV string and writes it to disk.
///
/// CSV rules (RFC 4180 compliant):
/// - First row is the header.
/// - Fields containing commas, double-quotes, or newlines are wrapped in double-quotes.
/// - Internal double-quotes are escaped by doubling: " → ""
/// - Newlines within fields are replaced with a space (keeps rows on one line).
struct ExportManager {

    // MARK: - Public API

    /// Present an NSSavePanel and, if the user confirms, write the CSV to the chosen URL.
    ///
    /// - Parameter books: The current page / filter result to export.
    @MainActor
    static func presentExportPanel(books: [CalibreBook]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Ambrosia Export.csv"
        panel.message = "Choose a location to save the CSV export."
        panel.prompt  = "Export"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let csv = exportToCSV(books: books)
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Build the CSV string from an array of `CalibreBook` values.
    ///
    /// Columns: Title, Authors, Series, Tags, Word Count, Kudos, Published Date.
    /// Authors and Tags are semicolon-separated within their cells.
    static func exportToCSV(books: [CalibreBook]) -> String {
        let header = ["Title", "Authors", "Series", "Tags",
                      "Word Count", "Kudos", "Published Date"]

        var rows: [[String]] = [header]

        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale     = Locale(identifier: "en_US_POSIX")
            return f
        }()

        for book in books {
            let seriesStr: String = {
                guard let s = book.series, !s.isEmpty else { return "" }
                if let idx = book.seriesIndex {
                    let idxStr = idx.truncatingRemainder(dividingBy: 1) == 0
                        ? String(Int(idx)) : String(idx)
                    return "\(s) #\(idxStr)"
                }
                return s
            }()

            let row: [String] = [
                book.title,
                book.authors.joined(separator: "; "),
                seriesStr,
                book.tags.joined(separator: "; "),
                book.wordCount.map(String.init) ?? "",
                book.kudos.map(String.init) ?? "",
                book.publishedDate.map { dateFormatter.string(from: $0) } ?? "",
            ]
            rows.append(row)
        }

        return rows.map { csvRow($0) }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Helpers

    /// Encode a single CSV row. Each field is escaped individually.
    private static func csvRow(_ fields: [String]) -> String {
        fields.map { csvEscape($0) }.joined(separator: ",")
    }

    /// Escape a single field per RFC 4180:
    /// - Replace internal newlines with a space (keeps rows on one line in most apps).
    /// - Wrap in quotes if the field contains a comma, quote, or newline.
    /// - Double any internal quotes.
    private static func csvEscape(_ field: String) -> String {
        // Normalise embedded newlines to a space so the file stays one-row-per-book
        let sanitised = field.replacingOccurrences(of: "\r\n", with: " ")
                             .replacingOccurrences(of: "\n",   with: " ")
                             .replacingOccurrences(of: "\r",   with: " ")
        let needsQuoting = sanitised.contains(",") || sanitised.contains("\"")
        if needsQuoting {
            let escaped = sanitised.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return sanitised
    }
}
