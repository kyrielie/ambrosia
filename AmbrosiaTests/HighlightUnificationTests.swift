import XCTest
@testable import Ambrosia

final class HighlightUnificationTests: XCTestCase {

    func testLegacyHexMapsToSemanticAnnotationColor() {
        XCTAssertEqual(AnnotationColor(legacyHex: "#FFD60A"), .yellow)
        XCTAssertEqual(AnnotationColor(legacyHex: "#ffcc00"), .yellow)
        XCTAssertEqual(AnnotationColor(legacyHex: "#FF453A"), .red)
        XCTAssertEqual(AnnotationColor(legacyHex: "#30D158"), .green)
        XCTAssertEqual(AnnotationColor(legacyHex: "#0A84FF"), .blue)
        XCTAssertEqual(AnnotationColor(legacyHex: "#BF5AF2"), .purple)
        XCTAssertEqual(AnnotationColor(legacyHex: "#123456"), .yellow)
        XCTAssertEqual(AnnotationColor(legacyHex: nil), .yellow)
    }

    func testAllHighlightPalettesExposeDistinctLightAndDarkSets() {
        XCTAssertEqual(HighlightPalette.allCases.count, 9)
        for palette in HighlightPalette.allCases {
            for color in AnnotationColor.allCases {
                let light = palette.hex(for: color, isDark: false)
                let dark = palette.hex(for: color, isDark: true)
                XCTAssertTrue(light.hasPrefix("#"))
                XCTAssertTrue(dark.hasPrefix("#"))
            }
        }
        XCTAssertNotEqual(
            HighlightPalette.default.hexSet(isDark: false),
            HighlightPalette.default.hexSet(isDark: true)
        )
    }

    func testReaderPreferencesEmitsUnifiedHighlightVariablesAndCSS() {
        let prefs = ReaderPreferences.shared
        let vars = prefs.cssVariableDeclarations
        XCTAssertTrue(vars.contains("--ambrosia-hl-yellow:"))
        XCTAssertTrue(vars.contains("--ambrosia-hl-purple:"))
        XCTAssertTrue(vars.contains("--ambrosia-hl-opacity:"))

        let css = prefs.css(paginated: false)
        XCTAssertTrue(css.contains("mark.ambrosia-highlight"))
        XCTAssertTrue(css.contains("-webkit-box-decoration-break: clone"))
        XCTAssertTrue(css.contains("color-mix(in srgb"))
        XCTAssertTrue(css.contains("data-overlap=\"underline\""))
        XCTAssertTrue(css.contains("@keyframes ambrosia-highlight-flash"))
    }

    func testAnnotationColorKeySurvivesMetaDBRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-hl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let metaDB = try AmbrosiaMetaDB(libraryURL: dir)

        let annotation = Annotation(
            spineIndex: 2,
            startChar: 10,
            endChar: 42,
            selectedText: "sample quote",
            note: "test note",
            colorKey: .purple,
            colorHex: "#BF5AF2"
        )
        try await metaDB.insertAnnotation(annotation, calibreID: 99)

        let fetched = try await metaDB.annotations(for: 99, spineIndex: 2)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.colorKey, .purple)
        XCTAssertEqual(fetched.first?.note, "test note")
    }
}
