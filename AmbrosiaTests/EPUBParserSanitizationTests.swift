import XCTest
@testable import Ambrosia

final class EPUBParserSanitizationTests: XCTestCase {

    func testSanitiseStripsPublisherStylesAndActiveContent() {
        let rawHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Chapter 1</title>
            <link rel="stylesheet" href="style.css" type="text/css">
            <style>body { background: red; }</style>
            <script>alert('evil');</script>
        </head>
        <body onload="doEvil()" style="margin: 20px;">
            <p style="color: blue;" onclick="steal()">Hello <a href="javascript:alert(1)">World</a></p>
        </body>
        </html>
        """

        let result = EPUBParser.sanitise(rawHTML, userCSS: "body { font-size: 16px; }", spineIndex: 3)

        // Verifications
        XCTAssertFalse(result.contains("style.css"), "Publisher stylesheet link must be stripped")
        XCTAssertFalse(result.contains("background: red"), "Publisher style block must be stripped")
        XCTAssertFalse(result.contains("alert('evil')"), "Script block must be stripped")
        XCTAssertFalse(result.contains("onload="), "onload attribute must be stripped")
        XCTAssertFalse(result.contains("onclick="), "onclick attribute must be stripped")
        XCTAssertFalse(result.contains("javascript:alert(1)"), "javascript: URL must be stripped")
        XCTAssertFalse(result.contains("style="), "Inline style attributes must be stripped")

        // User CSS and spine index must be injected
        XCTAssertTrue(result.contains("body { font-size: 16px; }"), "User CSS must be injected")
        XCTAssertTrue(result.contains("window.currentSpineIndex = 3;"), "Spine index tracker must be injected")
        XCTAssertTrue(result.contains("Hello"), "Body text must be preserved")
    }

    func testExtractBodyContentExtractsOnlyInnerBody() {
        let rawHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <link rel="stylesheet" href="main.css">
            <title>Doc</title>
        </head>
        <body>
            <div id="content"><p>First chapter</p></div>
        </body>
        </html>
        """

        let body = EPUBParser.extractBodyContent(from: rawHTML, isFirstSpineItem: false)
        XCTAssertFalse(body.contains("<html"), "Must not contain html tags")
        XCTAssertFalse(body.contains("<body"), "Must not contain body tags")
        XCTAssertFalse(body.contains("main.css"), "Must not contain publisher stylesheet")
        XCTAssertTrue(body.contains("<p>First chapter</p>"), "Must contain inner content")
    }

    func testExtractBodyContentStripsRedundantPrefaceOnFirstItemOnly() {
        let prefaceHTML = """
        <html><body>
        <h2 class="toc-heading">Preface</h2>
        <p>Author's note and work summary</p>
        </body></html>
        """

        let firstSpineResult = EPUBParser.extractBodyContent(from: prefaceHTML, isFirstSpineItem: true)
        XCTAssertFalse(firstSpineResult.contains("Preface"), "Redundant preface heading must be stripped on first spine item")
        XCTAssertTrue(firstSpineResult.contains("Author's note and work summary"))

        let laterSpineResult = EPUBParser.extractBodyContent(from: prefaceHTML, isFirstSpineItem: false)
        XCTAssertTrue(laterSpineResult.contains("Preface"), "Preface heading must NOT be stripped on subsequent spine items")
    }

    func testExtractBodyContentLeadingIndentWhitespaceRemoval() {
        let indentedHTML = """
        <html><body>
        <p>   This is an indented paragraph.</p>
        <p>This is a normal paragraph.</p>
        </body></html>
        """

        let cleaned = EPUBParser.extractBodyContent(from: indentedHTML, isFirstSpineItem: false, removeParagraphIndents: true)
        XCTAssertTrue(cleaned.contains("<p>This is an indented paragraph.</p>"), "Leading space run inside paragraph must be trimmed")

        let preserved = EPUBParser.extractBodyContent(from: indentedHTML, isFirstSpineItem: false, removeParagraphIndents: false)
        XCTAssertTrue(preserved.contains("<p>   This is an indented paragraph.</p>"), "Leading whitespace should be preserved if preference is false")
    }

    func testExtractBodyContentFormatsAO3PrefaceCardOnFirstSpineItem() {
        let rawHTML = """
        <html><body>
        <div id="preface">
            <p class="message"><b>Super Title</b><br>Posted on AO3</p>
            <dl class="tags">
                <dt>Rating:</dt><dd>General</dd>
                <dt>Fandom:</dt><dd>Marvel</dd>
                <dt>Character:</dt><dd>Steve Rogers</dd>
            </dl>
        </div>
        </body></html>
        """

        let result = EPUBParser.extractBodyContent(from: rawHTML, isFirstSpineItem: true)
        XCTAssertTrue(result.contains("ao3-preface-card"), "First spine item preface must receive ao3-preface-card class")
        XCTAssertTrue(result.contains("class=\"wide\">Fandom:"), "Fandom dt must receive wide class")
        XCTAssertTrue(result.contains("class=\"wide\">Marvel</dd>"), "Fandom dd must receive wide class")
    }

    func testExtractBodyContentReplacesAO3TitlePageOnSecondSpineItem() {
        let titlePageHTML = """
        <html><body>
        <div id="preface" class="calibre1">
            <h1 class="calibre6">My Amazing Fic</h1>
            <div class="byline">by <a href="http://archiveofourown.org/users/test" rel="author">TestAuthor</a></div>
            <p class="calibre7">Summary</p>
            <blockquote class="userstuff"><p>This is the fic summary.</p></blockquote>
            <p class="calibre7">Notes</p>
            <blockquote class="userstuff"><p>Enjoy the story!</p></blockquote>
        </div>
        </body></html>
        """

        let result = EPUBParser.extractBodyContent(from: titlePageHTML, isFirstSpineItem: false)
        XCTAssertTrue(result.contains("class=\"ao3-title-page\""), "Must contain ao3-title-page container")
        XCTAssertTrue(result.contains("<h1 class=\"ao3-work-title\">My Amazing Fic</h1>"), "Must contain clean title")
        XCTAssertTrue(result.contains("class=\"ao3-work-byline\""), "Must contain clean byline")
        XCTAssertTrue(result.contains("class=\"ao3-work-summary\""), "Must contain summary module")
        XCTAssertTrue(result.contains("This is the fic summary."), "Must preserve summary text")
        XCTAssertTrue(result.contains("class=\"ao3-work-notes\""), "Must contain notes module")
        XCTAssertTrue(result.contains("Enjoy the story!"), "Must preserve notes text")
    }

    func testExtractBodyContentAO3LayoutOrderVariations() {
        let prefaceHTML = """
        <html><body>
        <div id="preface">
            <p class="message"><b>Super Title</b> by TestAuthor<br><a href="http://archiveofourown.org">Posted originally</a></p>
            <dl class="tags">
                <dt>Rating:</dt><dd>General</dd>
            </dl>
        </div>
        </body></html>
        """

        let titlePageHTML = """
        <html><body>
        <div id="preface">
            <h1>Super Title</h1>
            <div class="byline">by TestAuthor</div>
            <p>Summary</p>
            <blockquote><p>Summary content.</p></blockquote>
        </div>
        </body></html>
        """

        // 1. .ao3Web (Default)
        let webPreface = EPUBParser.extractBodyContent(from: prefaceHTML, isFirstSpineItem: true, ao3Order: .ao3Web)
        XCTAssertFalse(webPreface.contains("Posted originally"), "Default AO3 web order strips title/link from top of tags")
        XCTAssertFalse(webPreface.contains("Super Title"), "Default AO3 web order strips title from tags card")
        XCTAssertTrue(webPreface.contains("General"), "Tags are preserved")

        let webTitlePage = EPUBParser.extractBodyContent(from: titlePageHTML, isFirstSpineItem: false, ao3Order: .ao3Web)
        XCTAssertTrue(webTitlePage.contains("<h1 class=\"ao3-work-title\">Super Title</h1>"), "Title page has title")
        XCTAssertTrue(webTitlePage.contains("Summary content."), "Title page has summary")

        // 2. .titleFirst
        let titleFirstPreface = EPUBParser.extractBodyContent(from: prefaceHTML, isFirstSpineItem: true, ao3Order: .titleFirst)
        XCTAssertTrue(titleFirstPreface.contains("ao3-title-first-header"), "Title-first order has title block before tags")
        XCTAssertTrue(titleFirstPreface.contains("Super Title"), "Title is present in first spine item")
        XCTAssertFalse(titleFirstPreface.contains("Posted originally"), "Link is removed")

        let titleFirstTitlePage = EPUBParser.extractBodyContent(from: titlePageHTML, isFirstSpineItem: false, ao3Order: .titleFirst)
        XCTAssertFalse(titleFirstTitlePage.contains("ao3-work-title"), "Title-first order does not duplicate title on second spine")
        XCTAssertTrue(titleFirstTitlePage.contains("Summary content."), "Summary is preserved")

        // 3. .ao3EPUB
        let epubPreface = EPUBParser.extractBodyContent(from: prefaceHTML, isFirstSpineItem: true, ao3Order: .ao3EPUB)
        XCTAssertTrue(epubPreface.contains("Posted originally"), "AO3 EPUB order preserves top link")
        XCTAssertTrue(epubPreface.contains("Super Title"), "AO3 EPUB order preserves title above tags")

        let epubTitlePage = EPUBParser.extractBodyContent(from: titlePageHTML, isFirstSpineItem: false, ao3Order: .ao3EPUB)
        XCTAssertTrue(epubTitlePage.contains("<h1 class=\"ao3-work-title\">Super Title</h1>"), "AO3 EPUB order has title page title")
    }

    // MARK: - Spacer paragraphs

    private func spacerParagraphCount(in html: String) -> Int {
        let pattern = #"<p[^>]*class="[^"]*\bambrosia-spacer\b[^"]*""#
        return (try? NSRegularExpression(pattern: pattern))
            .map { $0.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)) } ?? -1
    }

    private let spacerFixture = """
    <html><body>
    <p class="calibre7">&#160;</p>
    <p>   </p>
    <p><br/></p>
    <p>&#160;<br/>&#160;<br/></p>
    <p>Real text</p>
    <p><em>styled</em></p>
    <p><img src="x.png"/></p>
    <p></p>
    <div>&#160;</div>
    </body></html>
    """

    func testSpacerParagraphsAreTaggedWhenEnabled() {
        let result = EPUBParser.extractBodyContent(
            from: spacerFixture, isFirstSpineItem: false, collapseSpacerParagraphs: true)

        // nbsp-only (keeps its publisher class), whitespace-only, br-only, mixed nbsp and br.
        XCTAssertEqual(spacerParagraphCount(in: result), 4)
        XCTAssertTrue(result.contains("calibre7"), "Existing class must be kept")
        XCTAssertTrue(result.contains("<p>Real text</p>"))
        XCTAssertTrue(result.contains("<p><em>styled</em></p>"), "A paragraph with an inline element is not a spacer")
        XCTAssertTrue(result.contains("<p></p>"), "A childless paragraph is not tagged")
        XCTAssertFalse(result.contains("<div class=\"ambrosia-spacer"), "Only paragraphs are tagged")
    }

    func testSpacerParagraphsAreUntouchedWhenDisabled() {
        let result = EPUBParser.extractBodyContent(from: spacerFixture, isFirstSpineItem: false)
        XCTAssertEqual(spacerParagraphCount(in: result), 0)
        XCTAssertFalse(result.contains("ambrosia-spacer"))
    }

    func testSpacerMarkingDoesNotChangeText() {
        func text(_ html: String) -> String {
            html
                .replacingOccurrences(of: "&#160;", with: "\u{00A0}")
                .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
                .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        }
        let off = EPUBParser.extractBodyContent(from: spacerFixture, isFirstSpineItem: false)
        let on = EPUBParser.extractBodyContent(
            from: spacerFixture, isFirstSpineItem: false, collapseSpacerParagraphs: true)
        XCTAssertEqual(text(on), text(off), "Class-only change: text, and so UTF-16 offsets, must be identical")
    }

    func testSanitiseTagsSpacersForPaginatedPath() {
        let result = EPUBParser.sanitise(
            spacerFixture, userCSS: "", spineIndex: 2, collapseSpacerParagraphs: true)
        XCTAssertEqual(spacerParagraphCount(in: result), 4)
    }

    // MARK: - Trim leading whitespace

    func testTrimStripsNonCollapsingIndentCharacters() {
        let html = "<html><body><p>&#160;&#160;&#8195;Nbsp indent</p><p>\u{3000}\u{3000}Ideographic</p><p>\t Tab</p></body></html>"
        let on = EPUBParser.extractBodyContent(from: html, isFirstSpineItem: false, removeParagraphIndents: true)
        XCTAssertTrue(on.contains("<p>Nbsp indent</p>"))
        XCTAssertTrue(on.contains("<p>Ideographic</p>"))
        XCTAssertTrue(on.contains("<p>Tab</p>"))
        let off = EPUBParser.extractBodyContent(from: html, isFirstSpineItem: false)
        XCTAssertFalse(off.contains("<p>Nbsp indent</p>"))
    }

    func testTrimLeavesBlankParagraphsAndInnerSpacesAlone() {
        let html = "<html><body><p>&#160;&#160;</p><p>&#160;<em>Styled</em></p><p>Keep  inner&#160;space</p></body></html>"
        let on = EPUBParser.extractBodyContent(
            from: html, isFirstSpineItem: false, removeParagraphIndents: true, collapseSpacerParagraphs: true)
        XCTAssertEqual(spacerParagraphCount(in: on), 1, "Blank paragraph must survive trimming so it can still be a spacer")
        XCTAssertTrue(on.contains("<p><em>Styled</em></p>"))
        XCTAssertTrue(on.contains("<p>Keep  inner"), "Only the leading run is trimmed")
    }
}
