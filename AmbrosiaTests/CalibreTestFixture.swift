import Foundation
import SQLite

// Marker type solely so `Bundle(for:)` resolves to the AmbrosiaTests test
// bundle. `Bundle.module` (the SPM resource-bundle accessor) does not exist
// here — this project is a plain Xcode project, not a Swift package, so the
// two .sql fixture files must be added to the AmbrosiaTests target's
// "Copy Bundle Resources" build phase and located via Bundle(for:) instead.
private final class BundleToken {}

// Loads a temp, disposable Calibre-shaped library folder (containing a
// `metadata.db`) built from calibre_fixture_schema.sql (extracted verbatim
// from a real library's schema — see extract_calibre_fixture.sh) plus
// calibre_fixture_data.sql (synthetic rows covering the edge cases listed
// in that file's header comment). Both .sql files must be added to the
// AmbrosiaTests target's resources, not just its sources.
//
// IMPORTANT: `CalibreLibrary.init(root:)` (Database/CalibreLibrary.swift:67)
// takes the *library folder*, not a db file path — it appends
// "metadata.db" itself internally. `makeTempLibraryRoot()` below returns
// that folder, matching the real initializer exactly (verified against the
// current source, not assumed).
//
// Usage in an XCTest case:
//
//   final class CalibreLibraryFilterTests: XCTestCase {
//       var library: CalibreLibrary!
//       var libraryRoot: URL!
//
//       override func setUpWithError() throws {
//           libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
//           library = try CalibreLibrary(root: libraryRoot)
//       }
//
//       override func tearDownWithError() throws {
//           try? FileManager.default.removeItem(at: libraryRoot)
//       }
//   }
//
// See CalibreLibraryFixtureTests.swift for concrete test cases built
// against this fixture and CalibreLibrary's actual (verified) API.

enum CalibreTestFixture {

    enum FixtureError: Error {
        case resourceNotFound(String)
    }

    /// Creates a fresh temp *library folder* containing a `metadata.db`
    /// built from schema + synthetic data, at a unique path per call, so
    /// parallel test runs and repeated setUp calls never collide or see
    /// stale state from a previous run.
    ///
    /// - Returns: the folder URL — pass this directly to
    ///   `CalibreLibrary(root:)`.
    static func makeTempLibraryRoot(bundle: Bundle = Bundle(for: BundleToken.self)) throws -> URL {
        let schemaSQL = try loadResource("calibre_fixture_schema", bundle: bundle)
        let dataSQL = try loadResource("calibre_fixture_data", bundle: bundle)

        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia_test_library_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let dbPath = libraryRoot.appendingPathComponent("metadata.db").path

        // SQLite.swift's Connection is what CalibreLibrary itself uses, so
        // building the fixture through the same library keeps this
        // consistent with how the app actually talks to the file, and
        // catches any accidental use of a syntax construct SQLite.swift's
        // bundled SQLite build doesn't support the same way the app would.
        // Opened writable here (fixture setup only) — CalibreLibrary itself
        // always opens metadata.db readonly (Invariant 1), and this
        // connection is discarded immediately after seeding.
        let db = try Connection(dbPath)
        try db.execute(schemaSQL)
        try db.execute(dataSQL)

        return libraryRoot
    }

    private static func loadResource(_ name: String, bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: "sql") else {
            throw FixtureError.resourceNotFound(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
