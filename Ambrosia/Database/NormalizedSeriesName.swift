import Foundation

enum NormalizedSeriesName {
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
