import XCTest
@testable import Ambrosia

final class ReaderPreferencesTests: XCTestCase {

    override func tearDown() {
        ReaderPreferences.shared.resetReaderToDefaults()
        super.tearDown()
    }

    func testPreferredReaderDefaultAndPersistence() {
        let prefs = ReaderPreferences.shared
        XCTAssertEqual(prefs.preferredReader, .inbuilt)

        prefs.preferredReader = .systemDefault
        XCTAssertEqual(prefs.preferredReader, .systemDefault)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "rp.preferredReader"), "systemDefault")

        prefs.preferredReader = .customApp
        XCTAssertEqual(prefs.preferredReader, .customApp)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "rp.preferredReader"), "customApp")
    }

    func testCustomReaderAppNameDerivation() {
        let prefs = ReaderPreferences.shared
        prefs.customReaderAppPath = ""
        XCTAssertEqual(prefs.customReaderAppName, "")

        prefs.customReaderAppPath = "/Applications/Honeycrisp.app"
        XCTAssertEqual(prefs.customReaderAppName, "Honeycrisp")

        prefs.customReaderAppPath = "/Applications/Calibre.app/Contents/MacOS/ebook-viewer.app"
        XCTAssertEqual(prefs.customReaderAppName, "ebook-viewer")
    }

    func testResetReaderRestoresPreferredReaderDefaults() {
        let prefs = ReaderPreferences.shared
        prefs.preferredReader = .customApp
        prefs.customReaderAppPath = "/Applications/Test.app"
        XCTAssertTrue(prefs.isReaderCustomized)

        prefs.resetReaderToDefaults()
        XCTAssertEqual(prefs.preferredReader, .inbuilt)
        XCTAssertEqual(prefs.customReaderAppPath, "")
    }

    func testAO3TailoredCSSEmission() {
        let prefs = ReaderPreferences.shared
        let emittedCSS = prefs.css(paginated: false)

        XCTAssertTrue(emittedCSS.contains("#preface"), "Must contain #preface styling for AO3 header")
        XCTAssertTrue(emittedCSS.contains("#preface dl.tags"), "Must style AO3 metadata tag list")
        XCTAssertTrue(emittedCSS.contains(".summary, .notes"), "Must style AO3 summary and author notes")
        XCTAssertTrue(emittedCSS.contains(".ao3-endmatter"), "Must style AO3 endmatter")
    }
}
