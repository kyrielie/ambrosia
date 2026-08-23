import XCTest
@testable import Ambrosia

/// Coverage for `AO3MetadataExtractor.extract(from:)` (`AO3MetadataExtractor.swift`),
/// using fixture HTML built from `docs/ao3_epub_html_reference.md`'s templates and
/// "Observed examples" tables, verified against the real implementation (not just
/// the doc's pseudocode -- see the `isComplete`/`completedDate` note below, where
/// the two diverge slightly from what the doc's own snippet suggests).
final class AO3MetadataExtractorTests: XCTestCase {

    // MARK: - Full realistic preface

    func testFullPrefacePopulatesEveryField() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Rating:</dt>
            <dd class="calibre4"><a href="/works/rating/explicit">Explicit</a></dd>
            <dt class="calibre3">Archive Warning:</dt>
            <dd class="calibre4"><a href="/warnings/no-warnings">No Archive Warnings Apply</a></dd>
            <dt class="calibre3">Category:</dt>
            <dd class="calibre4"><a href="/categories/mm">M/M</a></dd>
            <dt class="calibre3">Fandom:</dt>
            <dd class="calibre4"><a href="/tags/1">Voltron: Legendary Defender</a></dd>
            <dt class="calibre3">Relationship:</dt>
            <dd class="calibre4"><a href="/tags/2">Shiro/Lance (Voltron)</a></dd>
            <dt class="calibre3">Character:</dt>
            <dd class="calibre4"><a href="/tags/3">Shiro</a>, <a href="/tags/4">Lance</a></dd>
            <dt class="calibre3">Additional Tags:</dt>
            <dd class="calibre4"><a href="/tags/5">Angst</a></dd>
            <dt class="calibre3">Language:</dt>
            <dd class="calibre4">English</dd>
            <dt class="calibre3">Stats:</dt>
            <dd class="calibre5">Published: 2016-06-22\n  Completed: 2016-07-11\nWords: 21,069\nChapters: 5/5</dd>
            """,
            workID: "7531264",
            scheme: "https"
        )

        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.storyURL, "https://archiveofourown.org/works/7531264")
        XCTAssertEqual(record?.workID, "7531264")
        XCTAssertEqual(record?.rating, "Explicit")
        XCTAssertEqual(record?.warnings, ["No Archive Warnings Apply"])
        XCTAssertEqual(record?.categories, ["M/M"])
        XCTAssertEqual(record?.fandoms, ["Voltron: Legendary Defender"])
        XCTAssertEqual(record?.relationships, ["Shiro/Lance (Voltron)"])
        XCTAssertEqual(record?.characters, ["Shiro", "Lance"])
        XCTAssertEqual(record?.additionalTags, ["Angst"])
        XCTAssertEqual(record?.language, "English")
        XCTAssertEqual(record?.publishedDate, "2016-06-22")
        XCTAssertEqual(record?.updatedDate, "2016-07-11")
        XCTAssertEqual(record?.wordCount, 21069)
        XCTAssertEqual(record?.chapterCurrent, 5)
        XCTAssertEqual(record?.chapterTotal, 5)
        XCTAssertTrue(record?.isComplete ?? false)
    }

    func testStoryURLNormalizesHTTPToHTTPS() {
        let html = makePreface(dtddPairs: minimalStatsPair(), workID: "111", scheme: "http")
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.storyURL, "https://archiveofourown.org/works/111")
    }

    // MARK: - Invalid rating/category/warning dropped, not stored unvalidated

    func testUnrecognizedRatingIsDroppedNotStored() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Rating:</dt>
            <dd class="calibre4"><a href="/x">Some Future Rating Nobody Recognizes</a></dd>
            \(minimalStatsPair())
            """,
            workID: "222",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertNil(record?.rating)
    }

    func testUnrecognizedCategoryIsDroppedNotStored() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Category:</dt>
            <dd class="calibre4"><a href="/x">Not A Real Category</a></dd>
            \(minimalStatsPair())
            """,
            workID: "223",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.categories, [])
    }

    func testUnrecognizedWarningIsDroppedNotStored() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Archive Warning:</dt>
            <dd class="calibre4"><a href="/x">Not A Real Warning</a></dd>
            \(minimalStatsPair())
            """,
            workID: "224",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.warnings, [])
    }

    /// Preface-only spelling "Creator Chose Not To Use Archive Warnings" folds
    /// into the single canonical value also used by Calibre tags.
    func testCreatorChoseNotToWarningFoldsToCanonicalSpelling() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Archive Warning:</dt>
            <dd class="calibre4"><a href="/x">Creator Chose Not To Use Archive Warnings</a></dd>
            \(minimalStatsPair())
            """,
            workID: "225",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.warnings, ["Choose Not To Use Archive Warnings"])
    }

    // MARK: - Series field: three cases from the doc's observed examples

    func testSeriesTwoEntriesInOneDD() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Series:</dt>
            <dd class="calibre4">Part 7 of <a href="/series/344591">jack/parse tumblr prompts</a>,
            Part 1 of <a href="/series/523378">rentboy jack and stuff</a></dd>
            \(minimalStatsPair())
            """,
            workID: "300",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.series.count, 2)
        XCTAssertEqual(record?.series[0].name, "jack/parse tumblr prompts")
        XCTAssertEqual(record?.series[0].index, 7)
        XCTAssertEqual(record?.series[0].ao3ID, "344591")
        XCTAssertEqual(record?.series[1].name, "rentboy jack and stuff")
        XCTAssertEqual(record?.series[1].index, 1)
        XCTAssertEqual(record?.series[1].ao3ID, "523378")
    }

    func testSeriesSingleEntry() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Series:</dt>
            <dd class="calibre4">Part 1 of <a href="/series/506620">Sugar Sweet (OT3, ABO)</a></dd>
            \(minimalStatsPair())
            """,
            workID: "301",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.series.count, 1)
        XCTAssertEqual(record?.series[0].name, "Sugar Sweet (OT3, ABO)")
        XCTAssertEqual(record?.series[0].index, 1)
        XCTAssertEqual(record?.series[0].ao3ID, "506620")
    }

    /// A series `<dd>` with no "Part N of" prefix at all produces zero
    /// entries: `parseEPUBSeries`'s `pendingIndex` gating requires a matched
    /// "Part N of" text node before an `<a>` contributes an entry.
    func testSeriesNoPartPrefixProducesZeroEntries() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Series:</dt>
            <dd class="calibre4"><a href="/series/999">Some Series</a></dd>
            \(minimalStatsPair())
            """,
            workID: "302",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.series, [])
    }

    // MARK: - Stats field: both example blocks verbatim

    func testStatsPublishedOnlyBlock() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Stats:</dt>
            <dd class="calibre5">Published: 2016-07-19\nWords: 3,261\nChapters: 1/1</dd>
            """,
            workID: "400",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.publishedDate, "2016-07-19")
        XCTAssertEqual(record?.wordCount, 3261)
        XCTAssertEqual(record?.chapterCurrent, 1)
        XCTAssertEqual(record?.chapterTotal, 1)
        XCTAssertNil(record?.updatedDate)
        XCTAssertTrue(record?.isComplete ?? false) // chapterCurrent == chapterTotal
    }

    func testStatsPublishedCompletedUpdatedBlock() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Stats:</dt>
            <dd class="calibre5">Published: 2016-06-22\n  Completed: 2016-07-11\nWords: 21,069\nChapters: 5/5</dd>
            """,
            workID: "401",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.publishedDate, "2016-06-22")
        XCTAssertEqual(record?.wordCount, 21069)
        XCTAssertEqual(record?.chapterCurrent, 5)
        XCTAssertEqual(record?.chapterTotal, 5)
        // "Completed:" sets updatedDate too (parseStats' "completed" case).
        XCTAssertEqual(record?.updatedDate, "2016-07-11")
    }

    /// `isComplete` is true when chapterCurrent == chapterTotal *or* a
    /// "Completed:" stats key was present -- an OR condition. This proves the
    /// completedDate branch alone can drive isComplete true even when the
    /// chapter-count branch can't (chapters "5/?" leaves chapterTotal nil).
    func testIsCompleteTrueViaCompletedDateWhenChapterTotalUnknown() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Stats:</dt>
            <dd class="calibre5">Published: 2016-06-22\n  Completed: 2016-07-11\nWords: 500\nChapters: 5/?</dd>
            """,
            workID: "402",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.chapterCurrent, 5)
        XCTAssertNil(record?.chapterTotal)
        XCTAssertTrue(record?.isComplete ?? false, "isComplete must come from the completedDate OR-branch here")
    }

    // MARK: - No dl.tags at all

    func testNoDlTagsReturnsNil() {
        let html = "<body class=\"calibre\"><p>Just some other content, not an AO3 preface.</p></body>"
        XCTAssertNil(AO3MetadataExtractor.extract(from: html))
    }

    // MARK: - Chapters absent entirely -> 1/1 default

    /// Only fires when neither the `Chapters:` dt/dd pair nor Stats' embedded
    /// `Chapters:` token supplied a value -- construct a fixture that omits both.
    func testChaptersDefaultToOneOfOneWhenAbsentFromBothSources() {
        let html = makePreface(
            dtddPairs: """
            <dt class="calibre3">Stats:</dt>
            <dd class="calibre5">Published: 2016-07-19\nWords: 100</dd>
            """,
            workID: "500",
            scheme: "https"
        )
        let record = AO3MetadataExtractor.extract(from: html)
        XCTAssertEqual(record?.chapterCurrent, 1)
        XCTAssertEqual(record?.chapterTotal, 1)
    }

    // MARK: - Fixtures

    private func minimalStatsPair() -> String {
        "<dt class=\"calibre3\">Stats:</dt><dd class=\"calibre5\">Published: 2016-01-01\\nWords: 100\\nChapters: 1/1</dd>"
    }

    private func makePreface(dtddPairs: String, workID: String, scheme: String) -> String {
        """
        <body class="calibre">
          <div id="preface" class="calibre1">
            <h2 class="toc-heading" id="calibre_toc_2">Preface</h2>
            <p class="message">
              <b class="calibre2">A Test Work</b><br class="calibre1"/>
              Posted originally on the Archive of Our Own at
              <a href="\(scheme)://archiveofourown.org/works/\(workID)">this work's original posting</a>.
            </p>
            <div class="calibre1">
              <dl class="tags">
                \(dtddPairs)
              </dl>
            </div>
          </div>
        </body>
        """
    }
}
