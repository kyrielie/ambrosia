import Combine
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

    /// Documents why the live cosmetic path is not enough: the `p` rules that
    /// read `--ambrosia-text-align` / `--ambrosia-paragraph-indent` exist in the
    /// built stylesheet only when the preference is non-default at build time.
    func testOptionalParagraphRulesAreAbsentAtDefaults() {
        let prefs = ReaderPreferences.shared
        prefs.resetReaderToDefaults()

        let css = prefs.css(paginated: false)
        XCTAssertFalse(css.contains("text-indent: var(--ambrosia-paragraph-indent);"))
        XCTAssertFalse(css.contains("text-align: var(--ambrosia-text-align);"))
        XCTAssertEqual(prefs.cssRuleGate, ReaderPreferences.CSSRuleGate(customAlignment: false, customIndent: false))
    }

    func testCSSRuleGateTracksOptionalParagraphRules() {
        let prefs = ReaderPreferences.shared
        prefs.resetReaderToDefaults()

        prefs.paragraphIndent = 1.5
        XCTAssertEqual(prefs.cssRuleGate, ReaderPreferences.CSSRuleGate(customAlignment: false, customIndent: true))
        XCTAssertTrue(prefs.css(paginated: false).contains("text-indent: var(--ambrosia-paragraph-indent);"))
        XCTAssertTrue(prefs.css(paginated: true).contains("text-indent: var(--ambrosia-paragraph-indent);"))

        // Changing the value keeps the gate unchanged: this is the live path.
        let gateBefore = prefs.cssRuleGate
        prefs.paragraphIndent = 2.25
        XCTAssertEqual(prefs.cssRuleGate, gateBefore)
        XCTAssertTrue(prefs.cssVariableDeclarations.contains("--ambrosia-paragraph-indent: 2.25em;"))

        prefs.textAlignment = .left
        XCTAssertEqual(prefs.cssRuleGate, ReaderPreferences.CSSRuleGate(customAlignment: true, customIndent: true))
        XCTAssertTrue(prefs.css(paginated: false).contains("text-align: var(--ambrosia-text-align);"))

        // Left to Justified stays on the live path.
        let alignGate = prefs.cssRuleGate
        prefs.textAlignment = .justify
        XCTAssertEqual(prefs.cssRuleGate, alignGate)

        prefs.paragraphIndent = nil
        prefs.textAlignment = .book
        XCTAssertEqual(prefs.cssRuleGate, ReaderPreferences.CSSRuleGate(customAlignment: false, customIndent: false))
        XCTAssertFalse(prefs.cssVariableDeclarations.contains("--ambrosia-paragraph-indent"))
    }

    func testCollapseSpacerParagraphsPersistenceResetAndCSS() {
        let prefs = ReaderPreferences.shared
        prefs.resetReaderToDefaults()
        XCTAssertFalse(prefs.collapseSpacerParagraphs)

        prefs.collapseSpacerParagraphs = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "rp.collapseSpacerParagraphs"))
        XCTAssertTrue(prefs.isReaderCustomized)

        // The collapse rule is always present; the class decides what it hits.
        let css = prefs.css(paginated: false)
        XCTAssertTrue(css.contains("p.ambrosia-spacer { margin-top: 0 !important; margin-bottom: 0 !important; height: 0; overflow: hidden; }"))
        XCTAssertTrue(prefs.css(paginated: true).contains("p.ambrosia-spacer {"))

        prefs.resetReaderToDefaults()
        XCTAssertFalse(prefs.collapseSpacerParagraphs)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "rp.collapseSpacerParagraphs"))
    }

    func testCollapseSpacerParagraphsIsStructural() {
        let prefs = ReaderPreferences.shared
        prefs.resetReaderToDefaults()
        var kinds: [PreferenceChangeKind] = []
        let cancellable = prefs.preferenceChangeKind.sink { kinds.append($0) }
        prefs.collapseSpacerParagraphs = true
        cancellable.cancel()
        XCTAssertEqual(kinds, [.structural])
    }

    func testKeyBindingsDefaultsAndReset() {
        let prefs = ReaderPreferences.shared
        let defaults = ReaderPreferences.defaultKeyBindingsForReset

        XCTAssertEqual(defaults[.showTOCSidebar]?.character, "t")
        XCTAssertEqual(defaults[.likeCurrentWork]?.character, "l")
        XCTAssertEqual(defaults[.readLaterCurrentWork]?.character, "r")

        prefs.keyBindings[.showTOCSidebar] = KeyBinding(character: "u", modifiers: [.control])
        XCTAssertEqual(prefs.keyBindings[.showTOCSidebar]?.character, "u")

        prefs.resetReaderShortcutsToDefaults()
        XCTAssertEqual(prefs.keyBindings[.showTOCSidebar]?.character, "t")
    }
}
