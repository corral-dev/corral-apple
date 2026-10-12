import XCTest
@testable import Corral

final class NotificationPreviewTests: XCTestCase {
    func testReleaseNotificationFromOwnerCapture() {
        let source = "已发布 **[0.3.24 / 3042](https://github.com/NeatMacApps/NeatWebApp/releases/tag/v0.3.24)**，并覆盖安装到本机。"
        XCTAssertEqual(NotificationPreview.body(source, fallback: "Finished"), "已发布 0.3.24 / 3042，并覆盖安装到本机。")
    }

    func testBlockBoundariesAndFormatting() {
        XCTAssertEqual(NotificationPreview.body("# Result\n\n- **Installed**\n- *Verified*\n\n> Error `429`", fallback: ""), "Result\nInstalled\nVerified\nError 429")
    }

    func testCodeAndLiteralSymbolsSurvive() {
        let source = "`echo **/*.py && echo foo_bar`\n\n```sh\necho *.swift\n# comment\n```\n\n2 * 3 = 6; foo_bar"
        XCTAssertEqual(NotificationPreview.body(source, fallback: ""), "echo **/*.py && echo foo_bar\necho *.swift\n# comment\n2 * 3 = 6; foo_bar")
    }

    func testCJKEmphasisAndEscapedSymbols() {
        XCTAssertEqual(NotificationPreview.body("**完成**，保留 \\* 和 \\_", fallback: ""), "完成，保留 * 和 _")
    }

    func testReferenceLinksAndImageLabels() {
        XCTAssertEqual(NotificationPreview.body("[Release][v]\n\n![Preview](https://example.com/image.png)\n\n[v]: https://example.com/release", fallback: ""), "Release\nPreview")
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

    func testEmptyAndOversizedInput() {
        XCTAssertEqual(NotificationPreview.body(" \n\n", fallback: "Session finished"), "Session finished")
        XCTAssertEqual(NotificationPreview.body("---", fallback: "Session stopped with an error"), "Session stopped with an error")
        XCTAssertEqual(NotificationPreview.body(String(repeating: "x", count: 100_000), fallback: ""), String(repeating: "x", count: 159) + "…")
    }
}
