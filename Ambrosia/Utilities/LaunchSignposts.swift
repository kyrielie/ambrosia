import Foundation
import os

/// Release-capable timing for launch and page-load work.
///
/// `LibraryFilterDebug.log` is `#if DEBUG` only, so it cannot be used to
/// measure a Release build. These helpers emit `OSSignposter` intervals and
/// events (category "Launch") that show up in Instruments under Points of
/// Interest / os_signpost, and cost almost nothing when no tool is attached.
///
/// Usage: pair `begin` and `end` with the same literal name, ideally with a
/// `defer`. Every `begin` gets its own signpost id, so overlapping intervals
/// with the same name (for example two `loadPage` calls) pair correctly.
enum LaunchSignposts {
    static let signposter = OSSignposter(subsystem: "Ambrosia", category: "Launch")
    private static let logger = Logger(subsystem: "Ambrosia", category: "Launch")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// Runs a synchronous body inside a named interval.
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try body()
    }

    /// A point-in-time marker (no duration).
    static func event(_ name: StaticString) {
        signposter.emitEvent(name, id: signposter.makeSignpostID())
    }

    /// Records one `membershipVersion` bump with its caller, so the number of
    /// page-cache invalidations during open can be counted.
    static func membershipBump(caller: String, newValue: Int) {
        event("membershipVersionBump")
        logger.info("membershipVersion -> \(newValue, privacy: .public) from \(caller, privacy: .public)")
    }
}
