import Foundation
import XCTest
@testable import Corral

final class ChatFileReferenceTests: XCTestCase {
    func testClassifyFileAndRelativeLinksButNotExternalURLs() throws {
        let fileURL = try XCTUnwrap(URL(string: "file:///Users/example/docs/CORE_PROFILE.md#L10-L20"))
        let fileLink = try XCTUnwrap(ChatFileLink.classify(fileURL))
        XCTAssertEqual(fileLink.displayName, "CORE_PROFILE.md")
        XCTAssertEqual(fileLink.targetLine, 10)
        XCTAssertTrue(fileLink.isMarkdown)

        let relURL = try XCTUnwrap(URL(string: "domains/macos-apps.md:42"))
        let relLink = try XCTUnwrap(ChatFileLink.classify(relURL))
        XCTAssertEqual(relLink.displayName, "macos-apps.md")
        XCTAssertEqual(relLink.targetLine, 42)
        XCTAssertNil(relLink.targetAnchor)
        XCTAssertTrue(relLink.isMarkdown)

        let anchorFileURL = try XCTUnwrap(URL(string: "../docs/GUIDE.md#Domain_Rules"))
        let anchorFileLink = try XCTUnwrap(ChatFileLink.classify(anchorFileURL))
        XCTAssertEqual(anchorFileLink.displayName, "GUIDE.md")
        XCTAssertNil(anchorFileLink.targetLine)
        XCTAssertEqual(anchorFileLink.targetAnchor, "domain-rules")
        XCTAssertTrue(anchorFileLink.isMarkdown)

        let pdfURL = try XCTUnwrap(URL(string: "file:///Users/example/report.pdf"))
        let pdfLink = try XCTUnwrap(ChatFileLink.classify(pdfURL))
        XCTAssertEqual(pdfLink.displayName, "report.pdf")
        XCTAssertFalse(pdfLink.isMarkdown)

        let httpsURL = try XCTUnwrap(URL(string: "https://example.com/guide.md"))
        XCTAssertNil(ChatFileLink.classify(httpsURL))

        let mailURL = try XCTUnwrap(URL(string: "mailto:hi@example.com"))
        XCTAssertNil(ChatFileLink.classify(mailURL))

        let anchorURL = try XCTUnwrap(URL(string: "#section"))
        XCTAssertNil(ChatFileLink.classify(anchorURL))
    }

    func testSanitizedFileNameStripsTraversalAndSlashes() {
        XCTAssertEqual(ChatFileLink.sanitizedFileName(".."), "file")
        XCTAssertEqual(ChatFileLink.sanitizedFileName("a/b/c.md"), "c.md")
        XCTAssertEqual(ChatFileLink.sanitizedFileName("CORE_PROFILE.md"), "CORE_PROFILE.md")
    }

    func testMarkdownDocumentParsesBlocksAndPreservesLinks() throws {
        let source = """
        # Title

        Read [Docs](https://example.com) and **bold**.

        - First
        - [x] Done task
          - Nested

        > Quote line

        ```swift
        let x = 1
        ```

        ```mermaid
        flowchart LR
          A --> B
        ```

        | Name | Status |
        |:---|:---:|
        | Core | Ready |

        ---
        """
        let doc = MarkdownDocument.parse(source)
        XCTAssertFalse(doc.truncatedToSource)

        var sawHeading = false
        var sawParagraph = false
        var sawList = false
        var sawSwiftCode = false
        var sawDiagram = false
        var sawQuote = false
        var sawTable = false
        var sawBreak = false

        for block in doc.blocks {
            switch block {
            case .heading(_, let level, let text):
                sawHeading = true
                XCTAssertEqual(level, 1)
                XCTAssertEqual(String(text.characters), "Title")
            case .paragraph(_, let text):
                sawParagraph = true
                XCTAssertTrue(String(text.characters).contains("bold"))
                let links = text.runs.compactMap(\.link)
                XCTAssertEqual(links.first?.absoluteString, "https://example.com")
            case .list(_, let items):
                sawList = true
                XCTAssertGreaterThanOrEqual(items.count, 3)
                XCTAssertNil(items[0].checked)
                XCTAssertEqual(items[1].checked, true)
                XCTAssertEqual(items[2].depth, 1)
            case .codeBlock(_, let lang, let code, let diagram):
                if lang == "swift" {
                    sawSwiftCode = true
                    XCTAssertTrue(code.contains("let x = 1"))
                    XCTAssertNil(diagram)
                } else if lang == "mermaid" {
                    sawDiagram = true
                    XCTAssertEqual(diagram?.kind, .mermaid)
                }
            case .blockQuote(_, let text):
                sawQuote = true
                XCTAssertEqual(String(text.characters), "Quote line")
            case .table(_, let alignments, let headers, let rows):
                sawTable = true
                XCTAssertEqual(alignments.count, 2)
                XCTAssertEqual(headers.map { String($0.characters) }, ["Name", "Status"])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0].map { String($0.characters) }, ["Core", "Ready"])
            case .thematicBreak:
                sawBreak = true
            }
        }

        XCTAssertTrue(sawHeading)
        XCTAssertTrue(sawParagraph)
        XCTAssertTrue(sawList)
        XCTAssertTrue(sawSwiftCode)
        XCTAssertTrue(sawDiagram)
        XCTAssertTrue(sawQuote)
        XCTAssertTrue(sawTable)
        XCTAssertTrue(sawBreak)
    }

    func testMarkdownDocumentExtractsHeadingsSourceLinesAndAnchors() throws {
        let source = """
        # Overview

        Intro paragraph.

        ## Setup Steps

        Details on line 7.

        ## Setup Steps

        Duplicate heading.
        """
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.headings.map(\.title), ["Overview", "Setup Steps", "Setup Steps"])
        XCTAssertEqual(doc.headings.map(\.anchor), ["overview", "setup-steps", "setup-steps-1"])

        let setupID = doc.blockID(forAnchor: "setup-steps")
        let dupID = doc.blockID(forAnchor: "setup-steps-1")
        XCTAssertNotNil(setupID)
        XCTAssertNotNil(dupID)
        XCTAssertNotEqual(setupID, dupID)

        let line7ID = doc.blockID(forLine: 7)
        XCTAssertNotNil(line7ID)
        XCTAssertEqual(doc.blockLineRanges[try XCTUnwrap(line7ID)]?.contains(7), true)
    }

    func testWireProtocolMediaFileDefaults() {
        XCTAssertEqual(WireProtocol.mMediaFile, "media.file")
        XCTAssertTrue(WireProtocol.usesDataPlane(WireProtocol.mMediaFile))
        XCTAssertTrue(WireProtocol.supportsMediaFile(fromHelloPayload: [
            "capabilities": ["media_file": true],
        ]))
        XCTAssertFalse(WireProtocol.supportsMediaFile(fromHelloPayload: [
            "capabilities": ["media_image": true],
        ]))
    }
}
