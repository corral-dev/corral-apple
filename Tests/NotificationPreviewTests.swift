import XCTest
@testable import Corral

final class NotificationPreviewTests: XCTestCase {
    func testReleaseNotificationFromOwnerCapture() {
        let source = "已发布 **[0.3.24 / 3042](https://github.com/NeatMacApps/NeatWebApp/releases/tag/v0.3.24)**，并覆盖安装到本机。"
        XCTAssertEqual(NotificationPreview.body(source, fallback: "Finished"), "已发布 0.3.24 / 3042，并覆盖安装到本机。")
    }

    func testBlockBoundariesAndFormatting() {
        XCTAssertEqual(NotificationPreview.body("# Result\n\n- **Installed**\n- *Verified*\n\n> Error `429`", fallback: ""), "Result Installed Verified Error 429")
    }

    func testCodeAndLiteralSymbolsSurvive() {
        let source = "`echo **/*.py && echo foo_bar`\n\n```sh\necho *.swift\n# comment\n```\n\n2 * 3 = 6; foo_bar"
        XCTAssertEqual(NotificationPreview.body(source, fallback: ""), "echo **/*.py && echo foo_bar echo *.swift # comment 2 * 3 = 6; foo_bar")
    }

    func testCJKEmphasisAndEscapedSymbols() {
        XCTAssertEqual(NotificationPreview.body("**完成**，保留 \\* 和 \\_", fallback: ""), "完成，保留 * 和 _")
    }

    func testReferenceLinksAndImageLabels() {
        XCTAssertEqual(NotificationPreview.body("[Release][v]\n\n![Preview](https://example.com/image.png)\n\n[v]: https://example.com/release", fallback: ""), "Release Preview")
    }

    func testConversionPrecedesTruncation() {
        let source = "[v1.2.3](https://example.com/" + String(repeating: "a", count: 500) + ") ready"
        XCTAssertEqual(NotificationPreview.body(source, fallback: ""), "v1.2.3 ready")
        let long = String(repeating: "👩🏽‍💻", count: 161)
        let result = NotificationPreview.body(long, fallback: "")
        XCTAssertEqual(result, String(long.prefix(159)) + "…")
        XCTAssertEqual(result.count, 160)
        XCTAssertEqual(NotificationPreview.body(String(repeating: "x", count: 160), fallback: ""), String(repeating: "x", count: 160))
    }

    func testWhitespaceCollapsesAfterMarkdownConversion() {
        let source = "# Result\r\n\r\n- **Installed**  \r\n- *Verified*\r\n\r\n```text\n\tError\t\t429\r\n\r\nRetry\u{0085}later\u{2028}on\u{2029}Monday\u{00A0}\u{3000}please  \n```"
        XCTAssertEqual(
            NotificationPreview.body(source, fallback: "Finished"),
            "Result Installed Verified Error 429 Retry later on Monday please"
        )
    }

    func testWhitespaceCollapsePrecedesTruncation() {
        let source = "```text\n" + String(repeating: "ready\t \r\n", count: 20) + "```"
        let expected = Array(repeating: "ready", count: 20).joined(separator: " ")
        XCTAssertEqual(NotificationPreview.body(source, fallback: "Finished"), expected)

        let long = "```text\n" + String(repeating: "👩🏽‍💻\r\n\t", count: 81) + "```"
        let result = NotificationPreview.body(long, fallback: "Finished")
        XCTAssertEqual(result, Array(repeating: "👩🏽‍💻", count: 80).joined(separator: " ") + "…")
        XCTAssertEqual(result.count, 160)
    }

    func testUnicodeWhitespaceOnlyUsesFallback() {
        XCTAssertEqual(
            NotificationPreview.body("\t\r\n\u{0085}\u{00A0}\u{2028}\u{2029}\u{3000}", fallback: "Session finished"),
            "Session finished"
        )
    }

    func testEmptyAndOversizedInput() {
        XCTAssertEqual(NotificationPreview.body(" \n\n", fallback: "Session finished"), "Session finished")
        XCTAssertEqual(NotificationPreview.body("---", fallback: "Session stopped with an error"), "Session stopped with an error")
        XCTAssertEqual(NotificationPreview.body(String(repeating: "x", count: 100_000), fallback: ""), String(repeating: "x", count: 159) + "…")
    }
}
