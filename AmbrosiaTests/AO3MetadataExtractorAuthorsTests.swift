import XCTest
@testable import Ambrosia

/// Coverage for `AO3MetadataExtractor.parseAuthors(from:)`
/// (`AO3MetadataExtractor+Authors.swift`), which parses a *chapter* spine
/// item's `div.byline` HTML -- distinct from the preface `dl.tags` parsing
/// covered by `AO3MetadataExtractorTests`.
final class AO3MetadataExtractorAuthorsTests: XCTestCase {

    // MARK: - Single author, standard byline

    func testSingleAuthorLinkExtractsUsernamePseudProfileURL() {
        let html = """
        <div class="byline">by <a rel="author" href="https://archiveofourown.org/users/testuser/pseuds/testpseud">testpseud</a></div>
        """
        let authors = AO3MetadataExtractor.parseAuthors(from: html)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0].username, "testuser")
        XCTAssertEqual(authors[0].pseud, "testpseud")
        XCTAssertEqual(authors[0].profileURL, "https://archiveofourown.org/users/testuser/pseuds/testpseud")
        XCTAssertEqual(authors[0].source, .byline)
    }

    // MARK: - Same-name case: pseud == username -> pseud nil

    func testSameNamePseudEqualsUsernameYieldsNilPseud() {
        let html = """
        <div class="byline">by <a rel="author" href="/users/orphan_account/pseuds/orphan_account">orphan_account</a></div>
        """
        let authors = AO3MetadataExtractor.parseAuthors(from: html)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0].username, "orphan_account")
        XCTAssertNil(authors[0].pseud)
    }

    // MARK: - Two authors, co-authorship

    func testTwoAuthorLinksProduceTwoEntriesBothBylineSource() {
        let html = """
        <div class="byline">by <a rel="author" href="/users/alice/pseuds/alice">alice</a> and <a rel="author" href="/users/bob/pseuds/bob">bob</a></div>
        """
        let authors = AO3MetadataExtractor.parseAuthors(from: html)
        XCTAssertEqual(authors.count, 2)
        XCTAssertEqual(authors[0].username, "alice")
        XCTAssertEqual(authors[1].username, "bob")
        XCTAssertTrue(authors.allSatisfy { $0.source == .byline })
    }

    // MARK: - No <a> at all, "by Anonymous"

    func testAnonymousByAnonymousProducesFixedCollectionURL() {
        let html = """
<div class="byline">by Anonymous</div>
"""
        let authors = AO3MetadataExtractor.parseAuthors(from: html)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0].username, "Anonymous")
        XCTAssertNil(authors[0].pseud)
        XCTAssertEqual(authors[0].profileURL, "https://archiveofourown.org/collections/anonymous")
        XCTAssertEqual(authors[0].source, .byline)
    }

    // MARK: - No <a>, other plain-text byline

    func testOtherPlainTextBylineSetsUsernameFromTrimmedText() {
        let html = """
<div class="byline">by SomeDeletedAccount</div>
"""
        let authors = AO3MetadataExtractor.parseAuthors(from: html)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0].username, "SomeDeletedAccount")
        XCTAssertNil(authors[0].pseud)
        XCTAssertNil(authors[0].profileURL)
    }

    // MARK: - No div.byline present at all

    func testNoBylineElementReturnsEmptyArray() {
        let html = "<div class=\"chapter\"><h1>Chapter 1</h1><p>Story text.</p></div>"
        XCTAssertEqual(AO3MetadataExtractor.parseAuthors(from: html), [])
    }

    // MARK: - Empty pseud segment in href also nils out to pseud == nil

    /// `pseudRaw?.isEmpty != false` -- an empty (not just equal-to-username)
    /// pseud path segment also collapses to nil, not an empty string.
    func testEmptyPseudSegmentInHrefYieldsNilPseud() {
        let html = """
        <div class="byline">by <a rel="author" href="/users/testuser/pseuds/">testuser</a></div>
        """
        let authors = AO3MetadataExtractor.parseAuthors(from: html)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0].username, "testuser")
        XCTAssertNil(authors[0].pseud)
    }

    // MARK: - findBylineAuthors window and scan semantics

    func testFindBylineAuthorsFoundAtPrefacePlusOne() {
        let chapter1 = "<div class=\"byline\">by <a rel=\"author\" href=\"/users/alice/pseuds/alice\">alice</a></div>"
        let authors = AO3MetadataExtractor.findBylineAuthors(spineCount: 5, after: 0) { idx in
            idx == 1 ? chapter1 : nil
        }
        XCTAssertEqual(authors.map(\.username), ["alice"])
    }

    func testFindBylineAuthorsFoundAtPrefacePlusTwo() {
        let toc = "<div>Table of Contents</div>"
        let chapter1 = "<div class=\"byline\">by <a rel=\"author\" href=\"/users/bob/pseuds/bob\">bob</a></div>"
        let authors = AO3MetadataExtractor.findBylineAuthors(spineCount: 5, after: 0) { idx in
            if idx == 1 { return toc }
            if idx == 2 { return chapter1 }
            return nil
        }
        XCTAssertEqual(authors.map(\.username), ["bob"])
    }

    func testFindBylineAuthorsNotFoundAtPrefacePlusThreeWithDefaultWindow() {
        let toc = "<div>TOC</div>"
        let intro = "<div>Intro</div>"
        let chapter1 = "<div class=\"byline\">by <a rel=\"author\" href=\"/users/carol/pseuds/carol\">carol</a></div>"
        let authors = AO3MetadataExtractor.findBylineAuthors(spineCount: 5, after: 0) { idx in
            if idx == 1 { return toc }
            if idx == 2 { return intro }
            if idx == 3 { return chapter1 }
            return nil
        }
        XCTAssertTrue(authors.isEmpty)
    }

    func testFindBylineAuthorsPrefaceIsLastSpineItemReturnsEmpty() {
        var called = false
        let authors = AO3MetadataExtractor.findBylineAuthors(spineCount: 3, after: 2) { _ in
            called = true
            return "<div class=\"byline\">by <a rel=\"author\" href=\"/users/dave/pseuds/dave\">dave</a></div>"
        }
        XCTAssertTrue(authors.isEmpty)
        XCTAssertFalse(called)
    }

    func testFindBylineAuthorsNilLoadHTMLContinuesToNextCandidate() {
        let chapter1 = "<div class=\"byline\">by <a rel=\"author\" href=\"/users/eve/pseuds/eve\">eve</a></div>"
        let authors = AO3MetadataExtractor.findBylineAuthors(spineCount: 4, after: 0) { idx in
            if idx == 1 { return nil }
            if idx == 2 { return chapter1 }
            return nil
        }
        XCTAssertEqual(authors.map(\.username), ["eve"])
    }

    func testFindBylineAuthorsNoBylineAnywhereReturnsEmpty() {
        let authors = AO3MetadataExtractor.findBylineAuthors(spineCount: 5, after: 0) { _ in
            "<p>Just plain text without byline</p>"
        }
        XCTAssertTrue(authors.isEmpty)
    }
}
