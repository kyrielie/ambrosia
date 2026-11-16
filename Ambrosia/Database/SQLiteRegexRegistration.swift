// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import SQLite

// swiftlint:disable:next identifier_name
private let SQLITE_DETERMINISTIC: Int32 = 0x0000_0800

/// Thread-safe LRU cache for compiled `NSRegularExpression` instances.
public final class RegexCache: @unchecked Sendable {
    public static let shared = RegexCache()

    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    public func regex(for pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)"
        lock.lock()
        defer { lock.unlock() }

        if let existing = cache[key] {
            return existing
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        if order.count >= capacity {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        order.append(key)
        cache[key] = compiled
        return compiled
    }

    public func matchesRegex(pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        guard let regex = regex(for: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    public func matchesWord(word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "\\b\(escaped)\\b"
        return matchesRegex(pattern: pattern, in: text, options: [.caseInsensitive])
    }
}

/// Custom SQLite scalar function `regexp(pattern, text)` allowing `column REGEXP pattern` in SQL queries.
public enum SQLiteRegexRegistration {

    /// Registers the `regexp` scalar function on a raw SQLite connection pointer.
    public static func register(on db: OpaquePointer) {
        sqlite3_create_function_v2(
            db, "regexp", 2,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, argumentCount, arguments in
                guard argumentCount >= 2, let arguments,
                      let patternBytes = sqlite3_value_text(arguments[0]),
                      let textBytes = sqlite3_value_text(arguments[1])
                else {
                    sqlite3_result_int(context, 0)
                    return
                }
                let pattern = String(cString: patternBytes)
                let text = String(cString: textBytes)
                let matches = RegexCache.shared.matchesRegex(pattern: pattern, in: text)
                sqlite3_result_int(context, matches ? 1 : 0)
            },
            nil, nil, nil
        )
    }

    /// Convenience for SQLite.swift `Connection`.
    public static func register(on connection: Connection) {
        register(on: connection.handle)
    }
}
