import XCTest
@testable import Ambrosia

final class ExternalAO3MetadataExtractorTests: XCTestCase {

    // MARK: - FanFicFare Tests

    func testFanFicFareAO3Parsing() {
        let html = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>transatlanticism by nerdylizj</title></head>
        <body class="fff_titlepage">
          <h3><a href="https://archiveofourown.org/works/25132513">transatlanticism</a> by <a class='authorlink' href='https://archiveofourown.org/users/nerdylizj/pseuds/nerdylizj'>nerdylizj</a></h3>
          <div>
            <b>Rating:</b> Mature<br />
            <b>Warnings:</b> Graphic Depictions Of Violence<br />
            <b>Relationships:</b> Annabeth Chase/Percy Jackson<br />
            <b>Category:</b> Percy Jackson and the Olympians<br />
            <b>Genre:</b> Hurt/Comfort, Romance<br />
            <b>Series:</b> <a class='serieslink' href='https://archiveofourown.org/series/1863706'>transatlanticism [1]</a><br />
            <b>Published:</b> 2020-07-07<br />
            <b>Updated:</b> 2020-08-09<br />
            <b>Words:</b> 67,473<br />
            <b>Chapters:</b> 7/7<br />
            <b>Status:</b> Completed<br />
          </div>
        </body>
        </html>
        """

        guard let record = AO3MetadataExtractor.extract(from: html) else {
            XCTFail("Failed to extract metadata from FanFicFare HTML")
            return
        }

        XCTAssertEqual(record.workID, "25132513")
        XCTAssertEqual(record.authors.first?.username, "nerdylizj")
        XCTAssertEqual(record.authors.first?.source, .byline)
        XCTAssertEqual(record.rating, "Mature")
        XCTAssertEqual(record.warnings, ["Graphic Depictions Of Violence"])
        XCTAssertEqual(record.relationships, ["Annabeth Chase/Percy Jackson"])
        XCTAssertEqual(record.fandoms, ["Percy Jackson and the Olympians"])
        XCTAssertEqual(record.additionalTags, ["Hurt/Comfort", "Romance"])
        XCTAssertEqual(record.wordCount, 67473)
        XCTAssertEqual(record.chapterCurrent, 7)
        XCTAssertEqual(record.chapterTotal, 7)
        XCTAssertTrue(record.isComplete)
        XCTAssertEqual(record.series.first?.name, "transatlanticism")
        XCTAssertEqual(record.series.first?.index, 1)
        XCTAssertEqual(record.series.first?.ao3ID, "1863706")
    }

    func testFanFicFareFFNSkipped() {
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body class="fff_titlepage">
          <h3><a href="https://www.fanfiction.net/s/12345/1/">Story</a> by Author</h3>
          <b>Rating:</b> T<br />
        </body>
        </html>
        """
        XCTAssertNil(AO3MetadataExtractor.extract(from: html))
    }

    // MARK: - FicLab Tests

    func testFicLabAO3Parsing() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Summary</title></head>
        <body class="fl-summary">
          <table>
            <tr><th>title</th><td>Senescence</td></tr>
            <tr><th>author</th><td>JoyDragon</td></tr>
            <tr><th>source</th><td><a href="https://archiveofourown.org/works/38946447">AO3</a></td></tr>
            <tr><th>published</th><td>May 12th, 2022</td></tr>
            <tr><th>updated</th><td>May 12th, 2022</td></tr>
            <tr><th>words</th><td>406</td></tr>
            <tr><th>chapters</th><td>1</td></tr>
            <tr><th>status</th><td>Complete</td></tr>
            <tr><th>rating</th><td>General Audiences</td></tr>
            <tr><th>tags</th><td>Aang &amp; Sokka (Avatar), Avatar: The Last Airbender, Complete, Old Age</td></tr>
          </table>
        </body>
        </html>
        """

        guard let record = AO3MetadataExtractor.extract(from: html) else {
            XCTFail("Failed to extract metadata from FicLab HTML")
            return
        }

        XCTAssertEqual(record.workID, "38946447")
        XCTAssertEqual(record.authors.first?.username, "JoyDragon")
        XCTAssertEqual(record.rating, "General Audiences")
        XCTAssertEqual(record.wordCount, 406)
        XCTAssertEqual(record.chapterCurrent, 1)
        XCTAssertTrue(record.isComplete)
        XCTAssertTrue(record.relationships.contains("Aang & Sokka (Avatar)"))
        XCTAssertTrue(record.additionalTags.contains("Avatar: The Last Airbender"))
        XCTAssertTrue(record.additionalTags.contains("Old Age"))
    }

    func testFicLabFFNSkipped() {
        let html = """
        <html>
        <body class="fl-summary">
          <table>
            <tr><th>author</th><td>Writer</td></tr>
            <tr><th>source</th><td><a href="https://www.fanfiction.net/s/987654">FFN</a></td></tr>
          </table>
        </body>
        </html>
        """
        XCTAssertNil(AO3MetadataExtractor.extract(from: html))
    }

    // MARK: - FicHub Tests

    func testFicHubAO3Parsing() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Introduction</title></head>
        <body>
          <h1>Senescence</h1>
          <p><b>By: JoyDragon</b></p>
          <p>Words: 393</p>
          <p>Status: completed</p>
          <p>Published: 2022-05-12</p>
          <p>Original source: <a href="https://archiveofourown.org/works/38946447">https://archiveofourown.org/works/38946447</a></p>
          <p>Exported with the assistance of <a href="https://fichub.net">FicHub.net</a></p>
        </body>
        </html>
        """

        guard let record = AO3MetadataExtractor.extract(from: html) else {
            XCTFail("Failed to extract metadata from FicHub HTML")
            return
        }

        XCTAssertEqual(record.workID, "38946447")
        XCTAssertEqual(record.authors.first?.username, "JoyDragon")
        XCTAssertEqual(record.wordCount, 393)
        XCTAssertEqual(record.publishedDate, "2022-05-12")
        XCTAssertTrue(record.isComplete)
    }

    func testFicHubFFNSkipped() {
        let html = """
        <html>
        <body>
          <p><b>By: Writer</b></p>
          <p>Original source: <a href="https://www.fanfiction.net/s/112233/1/">FFN</a></p>
          <p>Exported with the assistance of <a href="https://fichub.net">FicHub.net</a></p>
        </body>
        </html>
        """
        XCTAssertNil(AO3MetadataExtractor.extract(from: html))
    }
}
