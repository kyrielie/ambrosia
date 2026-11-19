import Foundation

/// Counts words in raw (X)HTML bytes without building a `String` or running a regex.
///
/// Mirrors the counting `book_index.word_count` used before: strip `<[^>]+>` (tag
/// text removed, nothing inserted in its place), then split on whitespace and
/// newlines. Entities are not decoded, same as before. Used for books with no AO3
/// stated word count; AO3 books store AO3's own value instead.
enum EPUBWordCounter {

    static func wordCount(inMarkup data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            let total = bytes.count
            var pos = 0
            var words = 0
            var inWord = false
            while pos < total {
                if bytes[pos] == 0x3C { // "<": skip a whole tag only when `<[^>]+>` would match
                    var close = pos + 1
                    while close < total && bytes[close] != 0x3E { close += 1 }
                    if close < total && close > pos + 1 {
                        pos = close + 1
                        continue
                    }
                    // No closing ">" or empty "<>": the "<" is ordinary text.
                }
                let spaceLength = whitespaceLength(bytes, at: pos, count: total)
                if spaceLength > 0 {
                    inWord = false
                    pos += spaceLength
                } else {
                    if !inWord { words += 1; inWord = true }
                    pos += 1
                }
            }
            return words
        }
    }

    /// Byte length of the whitespace scalar starting at `i`, or 0 if it is not whitespace.
    /// Covers ASCII whitespace plus the Unicode White_Space scalars `Character.isWhitespace`
    /// accepts in practice (NEL, NBSP, U+1680, U+2000..U+200A, U+2028/9, U+202F, U+205F, U+3000).
    private static func whitespaceLength(_ bytes: UnsafeBufferPointer<UInt8>, at pos: Int, count total: Int) -> Int {
        let lead = bytes[pos]
        switch lead {
        case 0x09...0x0D, 0x20: return 1
        case 0xC2:
            if pos + 1 < total, bytes[pos + 1] == 0x85 || bytes[pos + 1] == 0xA0 { return 2 }
        case 0xE1:
            if pos + 2 < total, bytes[pos + 1] == 0x9A, bytes[pos + 2] == 0x80 { return 3 }
        case 0xE2:
            if pos + 2 < total {
                let second = bytes[pos + 1]
                let third = bytes[pos + 2]
                if second == 0x80, (0x80...0x8A).contains(third) || third == 0xA8
                    || third == 0xA9 || third == 0xAF { return 3 }
                if second == 0x81, third == 0x9F { return 3 }
            }
        case 0xE3:
            if pos + 2 < total, bytes[pos + 1] == 0x80, bytes[pos + 2] == 0x80 { return 3 }
        default: break
        }
        return 0
    }
}
