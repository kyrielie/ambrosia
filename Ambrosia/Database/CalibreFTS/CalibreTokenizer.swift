// SPDX-License-Identifier: GPL-3.0-only
// Derived from calibre src/calibre/db/sqlite_extension.cpp, Copyright (C) 2021 Kovid Goyal, GPL v3.
import Foundation

/// One token emitted by the Calibre-compatible tokenizer.
struct CalibreToken: Equatable, Sendable {
    let text: String
    /// Byte offsets into the UTF-8 input.
    let start: Int
    let end: Int
    /// True for the diacritic-stripped companion token emitted at index time.
    let colocated: Bool
}

/// Swift face of the C tokenizer port (`calibre_tokenizer.c`). Used by tests and
/// diagnostics; the FTS5 integration calls the C API directly.
enum CalibreTokenizer {

    enum Mode: Sendable {
        case document
        case query
        case aux

        fileprivate var flags: Int32 {
            switch self {
            case .document: return Int32(CALIBRE_TOKENIZE_DOCUMENT)
            case .query: return Int32(CALIBRE_TOKENIZE_QUERY)
            case .aux: return Int32(CALIBRE_TOKENIZE_AUX)
            }
        }
    }

    private final class Collector {
        var tokens: [CalibreToken] = []
    }

    /// Tokenizes `text` the way Calibre's `calibre` FTS5 tokenizer does.
    ///
    /// - Parameter nfkc: applies NFKC first, mirroring Calibre's Python test helper and
    ///   the way Calibre normalizes queries. Document text is never NFKC-normalized.
    /// - Returns: an empty array when the C tokenizer cannot be created or fails.
    static func tokenize(
        _ text: String,
        mode: Mode = .document,
        removeDiacritics: Bool = true,
        nfkc: Bool = false
    ) -> [CalibreToken] {
        let input = nfkc ? text.precomposedStringWithCompatibilityMapping : text
        var options = calibre_tokenizer_options()
        options.remove_diacritics = removeDiacritics ? 1 : 0
        options.stem_words = 0
        guard let tokenizer = calibre_tokenizer_new(&options) else { return [] }
        defer { calibre_tokenizer_free(tokenizer) }

        let collector = Collector()
        let bytes = ContiguousArray<CChar>(input.utf8.map { CChar(bitPattern: $0) })
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let status = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            calibre_tokenizer_tokenize(
                tokenizer,
                mode.flags,
                buffer.baseAddress,
                Int32(buffer.count),
                { rawContext, flags, token, length, start, end -> Int32 in
                    guard let rawContext, let token, length >= 0 else { return Int32(CALIBRE_TOKENIZER_ERROR) }
                    let collector = Unmanaged<Collector>.fromOpaque(rawContext).takeUnretainedValue()
                    let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(token), count: Int(length))
                    collector.tokens.append(
                        CalibreToken(
                            text: String(decoding: raw, as: UTF8.self),
                            start: Int(start),
                            end: Int(end),
                            colocated: (flags & Int32(CALIBRE_TOKEN_COLOCATED)) != 0
                        )
                    )
                    return 0
                },
                context
            )
        }
        return status == 0 ? collector.tokens : []
    }
}
