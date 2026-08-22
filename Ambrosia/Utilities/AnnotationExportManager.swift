import Foundation
import AppKit

// MARK: - AnnotationExportRow

/// Bundles one annotation with the book it belongs to. Assembled once per
/// export (bulk book lookup via `CalibreLibrary.booksForIDs`), mirroring
/// `ExportRow` in ExportManager.swift — no N+1 queries.
struct AnnotationExportRow {
    let annotation: Annotation
    let book: CalibreBook
}

// MARK: - AnnotationExportManager

/// Exports every annotation (highlight or point annotation) in the current
/// library to a CSV file, alongside the book each one belongs to. Reuses
/// ExportManager's RFC 4180 CSV escaping (`csvRow`/`csvEscape`/`isoDate`)
/// so both exporters produce byte-for-byte consistent CSV formatting.
///
/// Was tracked as "Not Yet Built: Annotation export/sharing" in
/// docs/not-yet-built.md; see docs/annotations.md for the annotation model
/// this reads from.
struct AnnotationExportManager {

    /// Build the CSV string from an array of `AnnotationExportRow` values.
    ///
    /// Columns: Book Title, Authors, Type (Highlight / Bookmark), Selected
    /// Text, Note, Color, Spine Index, Created Date.
    static func exportToCSV(rows: [AnnotationExportRow]) -> String {
        let header = [
            "Book Title", "Authors", "Type", "Selected Text", "Note", "Color",
            "Spine Index", "Created Date"
        ]

        var csvRows: [[String]] = [header]

        for r in rows {
            csvRows.append([
                r.book.displayTitle,
                r.book.authors.joined(separator: "; "),
                r.annotation.isPointAnnotation ? "Bookmark" : "Highlight",
                r.annotation.selectedText,
                r.annotation.note ?? "",
                r.annotation.colorHex,
                String(r.annotation.spineIndex),
                ExportManager.isoDate(r.annotation.createdDate)
            ])
        }

        return csvRows.map { ExportManager.csvRow($0) }.joined(separator: "\r\n") + "\r\n"
    }

    /// Fetch every annotation in the library and resolve each one's book via
    /// a single bulk lookup (same pattern as ActivityFeedView's `load()`).
    /// Annotations whose book can't be resolved (e.g. a book removed from
    /// Calibre since the annotation was made) are silently dropped, the same
    /// tolerance ActivityFeedView already applies to its own merge step.
    @MainActor
    static func buildExportRows(session: LibrarySession) async -> [AnnotationExportRow] {
        guard let metaDB = session.metaDB, let library = session.library else { return [] }

        let annotations: [(annotation: Annotation, calibreID: Int)]
        do {
            annotations = try await metaDB.allAnnotations()
        } catch {
            return []
        }
        guard !annotations.isEmpty else { return [] }

        let ids = Array(Set(annotations.map(\.calibreID)))
        let bookMap: [Int: CalibreBook] = Dictionary(
            uniqueKeysWithValues: await library.booksForIDs(ids).map { ($0.id, $0) }
        )

        return annotations.compactMap { annotation, calibreID in
            guard let book = bookMap[calibreID] else { return nil }
            return AnnotationExportRow(annotation: annotation, book: book)
        }
    }

    /// Present an NSSavePanel and, if the user confirms, fetch every
    /// annotation, resolve books, and write the CSV. Mirrors
    /// `ExportManager.presentExportPanel` (§1).
    @MainActor
    static func presentExportPanel(session: LibrarySession) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Ambrosia Annotations.csv"
        panel.message = "Choose a location to save the annotation export."
        panel.prompt  = "Export"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let rows = await buildExportRows(session: session)
                guard !rows.isEmpty else {
                    let alert = NSAlert()
                    alert.messageText = "Nothing to Export"
                    alert.informativeText = "No annotations found in this library."
                    alert.alertStyle = .informational
                    alert.runModal()
                    return
                }
                let csv = exportToCSV(rows: rows)
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
    }
}
