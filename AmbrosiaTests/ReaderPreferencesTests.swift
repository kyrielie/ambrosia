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

    func testParagraphIndentModeMappingAndCSS() {
        let prefs = ReaderPreferences.shared
        prefs.resetReaderToDefaults()

        // 1. Default state: .bookDefault -> nil
        XCTAssertEqual(prefs.paragraphIndentMode, .bookDefault)
        XCTAssertNil(prefs.paragraphIndent)
        var css = prefs.css(paginated: false)
        XCTAssertFalse(css.contains("text-indent: var(--ambrosia-paragraph-indent);"))

        // 2. None state: .none -> 0.0em
        prefs.paragraphIndentMode = .none
        XCTAssertEqual(prefs.paragraphIndentMode, .none)
        XCTAssertEqual(prefs.paragraphIndent, 0.0)
        css = prefs.css(paginated: false)
        XCTAssertTrue(css.contains("--ambrosia-paragraph-indent: 0.0em;"))
        XCTAssertTrue(css.contains("text-indent: var(--ambrosia-paragraph-indent);"))

        // 3. Indented state: .indented -> default 1.5em (or custom)
        prefs.paragraphIndentMode = .indented
        XCTAssertEqual(prefs.paragraphIndentMode, .indented)
        XCTAssertEqual(prefs.paragraphIndent, 1.5)
        css = prefs.css(paginated: false)
        XCTAssertTrue(css.contains("--ambrosia-paragraph-indent: 1.5em;"))
        XCTAssertTrue(css.contains("text-indent: var(--ambrosia-paragraph-indent);"))

        // Adjusting indent value preserves .indented mode
        prefs.paragraphIndent = 2.0
        XCTAssertEqual(prefs.paragraphIndentMode, .indented)
        XCTAssertEqual(prefs.paragraphIndent, 2.0)

        // Switching back to bookDefault
        prefs.paragraphIndentMode = .bookDefault
        XCTAssertEqual(prefs.paragraphIndentMode, .bookDefault)
        XCTAssertNil(prefs.paragraphIndent)

        prefs.resetReaderToDefaults()
    }

    func testTypographyValueFormatParsingAndSnapping() {
        // 1. Parsing
        XCTAssertEqual(TypographyValueFormat.parseNumber("16 pt"), 16.0)
        XCTAssertEqual(TypographyValueFormat.parseNumber("18"), 18.0)
        XCTAssertEqual(TypographyValueFormat.parseNumber("1.5 em"), 1.5)
        XCTAssertEqual(TypographyValueFormat.parseNumber("1,75"), 1.75)
        XCTAssertEqual(TypographyValueFormat.parseNumber("600px"), 600.0)
        XCTAssertEqual(TypographyValueFormat.parseNumber("   2.25  "), 2.25)
        XCTAssertNil(TypographyValueFormat.parseNumber("invalid"))
        XCTAssertNil(TypographyValueFormat.parseNumber(""))

        // 2. Formatting
        XCTAssertEqual(TypographyValueFormat.format(value: 16.0, fractionDigits: 0, unit: "pt"), "16 pt")
        XCTAssertEqual(TypographyValueFormat.format(value: 1.4, fractionDigits: 1, unit: ""), "1.4")
        XCTAssertEqual(TypographyValueFormat.format(value: 1.50, fractionDigits: 2, unit: "em"), "1.5 em")
        XCTAssertEqual(TypographyValueFormat.format(value: 1.25, fractionDigits: 2, unit: "em"), "1.25 em")
        XCTAssertEqual(TypographyValueFormat.format(value: 600.0, fractionDigits: 0, unit: "px"), "600px")

        // 3. Clamping
        XCTAssertEqual(TypographyValueFormat.clamp(5.0, to: 10.0...36.0), 10.0)
        XCTAssertEqual(TypographyValueFormat.clamp(45.0, to: 10.0...36.0), 36.0)
        XCTAssertEqual(TypographyValueFormat.clamp(20.0, to: 10.0...36.0), 20.0)

        // 4. Snapping
        let snapped1 = TypographyValueFormat.snap(1.34, range: 1.0...3.0, step: 0.1, fractionDigits: 1)
        XCTAssertEqual(snapped1, 1.3)
        let snapped2 = TypographyValueFormat.snap(1.36, range: 1.0...3.0, step: 0.1, fractionDigits: 1)
        XCTAssertEqual(snapped2, 1.4)
    }
}
