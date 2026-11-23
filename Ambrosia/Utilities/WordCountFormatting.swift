import Foundation

/// Display formatting for word counts in library rows, the email sidebar and
/// full-text result cards. Previously four identical private copies.
enum WordCountFormatting {

    /// "850 words", "12.3k words", "1.25M words".
    static func label(_ count: Int) -> String {
        switch count {
        case 0..<1_000:
            return "\(count) words"
        case 0..<1_000_000:
            return String(format: "%.1fk words", Double(count) / 1_000)
        default:
            return String(format: "%.2fM words", Double(count) / 1_000_000)
        }
    }
}
