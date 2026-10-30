// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import SQLite

// swiftlint:disable:next identifier_name
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Custom SQLite scalar functions required by Calibre triggers:
/// `title_sort()` and `uuid4()` are called by `books_insert_trg`, `books_update_trg`,
/// `series_insert_trg`, and `series_update_trg`.
public enum CalibreFunctions {

    /// Registers `title_sort` and `uuid4` scalar functions on a raw SQLite connection pointer.
    public static func register(on db: OpaquePointer) {
        sqlite3_create_function_v2(
            db, "title_sort", 1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, argumentCount, arguments in
                guard argumentCount >= 1, let arguments,
                      let text = sqlite3_value_text(arguments[0])
                else {
                    sqlite3_result_null(context)
                    return
                }
                let result = CalibreFunctions.titleSort(String(cString: text))
                sqlite3_result_text(context, result, -1, SQLITE_TRANSIENT)
            },
            nil, nil, nil
        )

        sqlite3_create_function_v2(
            db, "uuid4", 0,
            SQLITE_UTF8, nil,
            { context, _, _ in
                sqlite3_result_text(context, UUID().uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            },
            nil, nil, nil
        )
    }

    /// Convenience for SQLite.swift `Connection`.
    public static func register(on connection: Connection) {
        register(on: connection.handle)
    }

    /// Matches Calibre's default `title_sort`: a leading article ("A", "The", "An") moves to the end.
    /// e.g. "The Hobbit" -> "Hobbit, The".
    public static func titleSort(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["A", "The", "An"] {
            let prefix = article + " "
            if trimmed.count > prefix.count,
               trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let rest = trimmed.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
                return "\(rest), \(trimmed.prefix(article.count))"
            }
        }
        return trimmed
    }

    /// Calibre's default `author_sort_copy_method` ("invert"): "Gergely Orosz" -> "Orosz, Gergely".
    public static func authorSort(_ author: String) -> String {
        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "i", "ii", "iii", "iv", "md", "m.d.", "m.d", "phd", "ph.d.", "ph.d"]
        var tokens = author.split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return author }

        var suffix = ""
        if let last = tokens.last, suffixes.contains(last.lowercased()) {
            suffix = " " + last
            tokens.removeLast()
        }
        guard tokens.count > 1, let family = tokens.last else { return author }
        let given = tokens.dropLast().joined(separator: " ")
        return "\(family)\(suffix), \(given)"
    }

    public static func authorSort(of authors: [String]) -> String {
        authors.map(authorSort).joined(separator: " & ")
    }

    /// Folder and file names safe across platforms and filesystems.
    public static func filenameSafe(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        var stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin

        for quote in ["ʹ", "ʺ", "’", "‘", "“", "”"] {
            stripped = stripped.replacingOccurrences(of: quote, with: "'")
        }
        stripped = String(stripped.unicodeScalars.filter { $0.isASCII })

        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = stripped
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
