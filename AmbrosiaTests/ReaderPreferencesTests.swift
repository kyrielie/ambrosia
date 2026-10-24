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

    func testAO3WorkLayoutOrderDefaultAndPersistence() {
        let prefs = ReaderPreferences.shared
        XCTAssertEqual(prefs.ao3WorkLayoutOrder, .ao3Web)

        prefs.ao3WorkLayoutOrder = .titleFirst
        XCTAssertEqual(prefs.ao3WorkLayoutOrder, .titleFirst)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "rp.ao3WorkLayoutOrder"), "titleFirst")

        prefs.ao3WorkLayoutOrder = .ao3EPUB
        XCTAssertEqual(prefs.ao3WorkLayoutOrder, .ao3EPUB)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "rp.ao3WorkLayoutOrder"), "ao3EPUB")

        prefs.resetReaderToDefaults()
        XCTAssertEqual(prefs.ao3WorkLayoutOrder, .ao3Web)
    }

    func testAppearanceModeAndThemes() {
        let prefs = ReaderPreferences.shared
        XCTAssertEqual(prefs.appearanceMode, .system)

        prefs.appearanceMode = .light
        XCTAssertEqual(prefs.appearanceMode, .light)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "rp.appearanceMode"), "light")
        XCTAssertFalse(prefs.effectiveIsDark)

        prefs.appearanceMode = .dark
        XCTAssertEqual(prefs.appearanceMode, .dark)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "rp.appearanceMode"), "dark")
        XCTAssertTrue(prefs.effectiveIsDark)

        let theme = ReaderTheme.sepia
        XCTAssertEqual(theme.colorSet(for: false).background, "#FBF0D9")
        XCTAssertEqual(theme.colorSet(for: true).background, "#2B2216")

        prefs.resetReaderToDefaults()
        XCTAssertEqual(prefs.appearanceMode, .system)
    }

    func testTextAlignmentAndIndentPersistenceAndCSS() {
        let prefs = ReaderPreferences.shared
        XCTAssertEqual(prefs.textAlignment, .book)
        XCTAssertNil(prefs.paragraphIndent)

        prefs.textAlignment = .justify
        XCTAssertEqual(prefs.textAlignment, .justify)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "rp.textAlignment"), "justify")

        prefs.paragraphIndent = 1.75
        XCTAssertEqual(prefs.paragraphIndent, 1.75)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "rp.paragraphIndent"), 1.75)

        let emittedCSS = prefs.css(paginated: false)
        XCTAssertTrue(emittedCSS.contains("--ambrosia-text-align: justify"), "Must emit text-align CSS variable")
        XCTAssertTrue(emittedCSS.contains("--ambrosia-paragraph-indent: 1.75em"), "Must emit paragraph-indent CSS variable")
        XCTAssertTrue(emittedCSS.contains("text-indent: var(--ambrosia-paragraph-indent);"), "Must style paragraph indent")

        prefs.resetReaderToDefaults()
        XCTAssertEqual(prefs.textAlignment, .book)
        XCTAssertNil(prefs.paragraphIndent)
    }
}
