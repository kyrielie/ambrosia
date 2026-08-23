import XCTest
@testable import Ambrosia

/// Coverage for `CustomColumnConfig` (`Ambrosia/Database/CustomColumnConfig.swift`).
///
/// `CustomColumnConfig.shared` proxies directly to `UserDefaults.standard`
/// under `"customColumn.wordCount"` / `"customColumn.kudos"`, with no
/// injectable store. Per the test plan's Tier 3 callout, this test saves
/// the real pre-test values in `setUpWithError` and restores them in
/// `tearDownWithError` rather than just clearing the keys, so a developer's
/// actual configured library column names aren't clobbered if this ever
/// runs against a real machine's defaults.
///
/// `autoDetect(using:)` is exercised against the real bundled Calibre
/// fixture (`CalibreTestFixture`), whose `custom_columns` table already
/// contains a `words` column (id 1) and a `kudos` column (id 7) -- see
/// `calibre_fixture_data.sql` -- so no additional fixture data is needed.
final class CustomColumnConfigTests: XCTestCase {

    private var savedWordCountLabel: String?
    private var savedKudosLabel: String?

    override func setUpWithError() throws {
        savedWordCountLabel = CustomColumnConfig.shared.wordCountLabel
        savedKudosLabel = CustomColumnConfig.shared.kudosLabel
        CustomColumnConfig.shared.wordCountLabel = nil
        CustomColumnConfig.shared.kudosLabel = nil
    }

    override func tearDownWithError() throws {
        CustomColumnConfig.shared.wordCountLabel = savedWordCountLabel
        CustomColumnConfig.shared.kudosLabel = savedKudosLabel
    }

    // MARK: - UserDefaults proxy

    func testWordCountLabelPersistsAndReadsBack() {
        CustomColumnConfig.shared.wordCountLabel = "words"
        XCTAssertEqual(CustomColumnConfig.shared.wordCountLabel, "words")
    }

    func testKudosLabelPersistsAndReadsBack() {
        CustomColumnConfig.shared.kudosLabel = "kudos"
        XCTAssertEqual(CustomColumnConfig.shared.kudosLabel, "kudos")
    }

    func testSettingWordCountLabelToNilRemovesKey() {
        CustomColumnConfig.shared.wordCountLabel = "words"
        CustomColumnConfig.shared.wordCountLabel = nil
        XCTAssertNil(UserDefaults.standard.object(forKey: "customColumn.wordCount"),
                     "setting nil should remove the key rather than store an empty string")
        XCTAssertNil(CustomColumnConfig.shared.wordCountLabel)
    }

    func testSettingKudosLabelToNilRemovesKey() {
        CustomColumnConfig.shared.kudosLabel = "kudos"
        CustomColumnConfig.shared.kudosLabel = nil
        XCTAssertNil(UserDefaults.standard.object(forKey: "customColumn.kudos"),
                     "setting nil should remove the key rather than store an empty string")
        XCTAssertNil(CustomColumnConfig.shared.kudosLabel)
    }

    // MARK: - autoDetect(using:)
    //
    // The shared fixture's custom_columns table only has "words" and "kudos"
    // as labels (calibre_fixture_data.sql rows 1 and 7), not any of the other
    // candidates ("word_count", "wordcount", "word count", "kudo"), so these
    // tests cover the not-already-set guard and a real match, but not the
    // candidate priority order (autoDetect's `candidates.first { ... }`).
    // Exercising priority order would need extra custom_columns rows; adding
    // them to the shared fixture risks perturbing the hardcoded row/count
    // expectations other tests (e.g. CalibreLibrarySearchTests) pin against
    // this same fixture, so that's left uncovered rather than risking that.

    func testAutoDetectPicksUpWordsAndKudosFromFixtureLibrary() async throws {
        let libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        let library = try CalibreLibrary(root: libraryRoot)

        await CustomColumnConfig.shared.autoDetect(using: library)

        XCTAssertEqual(CustomColumnConfig.shared.wordCountLabel, "words")
        XCTAssertEqual(CustomColumnConfig.shared.kudosLabel, "kudos")
    }

    func testAutoDetectDoesNotOverwriteAlreadyConfiguredLabels() async throws {
        let libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        let library = try CalibreLibrary(root: libraryRoot)

        // Pre-set to a value that is not among the candidate labels the
        // fixture's custom_columns table would otherwise match, so any
        // overwrite is unambiguously detectable.
        CustomColumnConfig.shared.wordCountLabel = "already_configured"
        CustomColumnConfig.shared.kudosLabel = "already_configured"

        await CustomColumnConfig.shared.autoDetect(using: library)

        XCTAssertEqual(CustomColumnConfig.shared.wordCountLabel, "already_configured")
        XCTAssertEqual(CustomColumnConfig.shared.kudosLabel, "already_configured")
    }
}
