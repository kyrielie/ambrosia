// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Represents a search term with an explicit matching mode (e.g. contains, exact, regex, word-boundary).
public struct SearchTerm: Equatable, Hashable, Sendable {
    public enum MatchMode: String, Codable, Sendable, Hashable {
        case contains
        case exact
        case regex
        case word
    }

    public let mode: MatchMode
    public let value: String

    public init(mode: MatchMode = .contains, value: String) {
        self.mode = mode
        self.value = value
    }

    /// Parses prefix syntax like `=value` or `~pattern` or `"word"`.
    public static func parse(prefixValue: String) -> SearchTerm {
        let trimmed = prefixValue.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("=") {
            var inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2 {
                inner = String(inner.dropFirst().dropLast())
            }
            return SearchTerm(mode: .exact, value: inner)
        } else if trimmed.hasPrefix("~") {
            var inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2 {
                inner = String(inner.dropFirst().dropLast())
            }
            return SearchTerm(mode: .regex, value: inner)
        } else {
            var inner = trimmed
            if inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2 {
                inner = String(inner.dropFirst().dropLast())
            }
            return SearchTerm(mode: .contains, value: inner)
        }
    }
}
