import XCTest
@testable import Ambrosia

/// Coverage for `EPUBParser.rewriteImageReferences(in:imageBaseURL:)`
/// (`Ambrosia/Reader/EPUBParser+ImagesAndTOC.swift:51`) -- the one function
/// in the EPUB-parsing family that's a pure string transform with no
/// archive/WKWebView dependency, so it doesn't need a fixture `.epub` on
/// disk, unlike the rest of that file.
final class EPUBImageReferenceRewriteTests: XCTestCase {

    private let base = URL(fileURLWithPath: "/tmp/ambrosia/42")

    func testRewritesDoubleQuotedImgSrc() {
        let html = #"<img src="images/cover.png" alt="cover">"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, #"<img src="file:///tmp/ambrosia/42/images/cover.png" alt="cover">"#)
    }

    func testRewritesSingleQuotedImgSrc() {
        let html = "<img src='images/cover.png' alt='cover'>"
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, "<img src='file:///tmp/ambrosia/42/images/cover.png' alt='cover'>")
    }

    func testRewritesDoubleQuotedImageXlinkHref() {
        let html = #"<image xlink:href="images/plate.svg"/>"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, #"<image xlink:href="file:///tmp/ambrosia/42/images/plate.svg"/>"#)
    }

    func testRewritesSingleQuotedImageXlinkHref() {
        let html = "<image xlink:href='images/plate.svg'/>"
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, "<image xlink:href='file:///tmp/ambrosia/42/images/plate.svg'/>")
    }

    func testDoesNotRewriteAlreadyAbsoluteFileURL() {
        let html = #"<img src="file:///already/absolute.png">"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, html)
    }

    func testDoesNotRewriteHTTPURL() {
        let html = #"<img src="https://example.com/cover.png">"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, html)
    }

    func testDoesNotRewriteHTTPSchemeURL() {
        let html = #"<img src="http://example.com/cover.png">"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, html)
    }

    func testDoesNotRewriteDataURL() {
        let html = #"<img src="data:image/png;base64,iVBORw0KGgo=">"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, html)
    }

    func testDoesNotRewriteAnchorHref() {
        // Explicitly not touched -- in-book link resolution is handled
        // separately and must keep seeing the original relative hrefs.
        let html = #"<a href="chapter2.xhtml">Next</a>"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(result, html)
    }

    func testRewritesMultipleImagesInSameDocument() {
        let html = #"<img src="a.png"><p>text</p><img src="b.png">"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: base)
        XCTAssertEqual(
            result,
            #"<img src="file:///tmp/ambrosia/42/a.png"><p>text</p><img src="file:///tmp/ambrosia/42/b.png">"#
        )
    }

    func testPercentEncodesSpacesInBasePath() {
        let spacedBase = URL(fileURLWithPath: "/tmp/ambrosia lib/42")
        let html = #"<img src="images/cover.png">"#
        let result = EPUBParser.rewriteImageReferences(in: html, imageBaseURL: spacedBase)
        XCTAssertEqual(result, #"<img src="file:///tmp/ambrosia%20lib/42/images/cover.png">"#)
    }
}
