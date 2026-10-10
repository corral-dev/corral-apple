#if os(iOS)
import XCTest
import UIKit
@testable import Corral

@MainActor
final class ChatMarkdownTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChatMarkdown.clearCacheForTests()
    }

    func testInlineMarkdownKeepsEmphasis() {
        let attributed = ChatMarkdown.attributed("hello **world**")
        let text = String(attributed.characters)
        XCTAssertTrue(text.contains("world"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertTrue(
            nsString(attributed).hasSemiboldOrBoldFont(containing: "world"),
            "short messages should still render strong emphasis"
        )
    }

    func testBubbleTextDropsLeadingAndTrailingBlanks() {
        let structured = String(ChatMarkdown.attributed("\n\n  ### Title\n\n- one\n- two\n\n\n  ").characters)
        XCTAssertEqual(structured.first, "T")
        XCTAssertEqual(structured.last, "o")

        let plain = String(ChatMarkdown.attributed("  hello\n\nworld \n\n").characters)
        XCTAssertEqual(plain.first, "h")
        XCTAssertEqual(plain.last, "d")
        XCTAssertTrue(plain.contains("\n"), "inner line breaks stay")

        let long = String(repeating: "a", count: ChatMarkdown.maxInlineMarkdownUTF8Count + 1)
        XCTAssertEqual(String(ChatMarkdown.attributed("\n " + long + " \n").characters), long)
    }

    func testHeadingsListsAndTablesBecomeVisibleStructure() {
        let source = """
        ### 效果
        - 打开旧会话时：先显示上次看过的尾巴
        - 换网重连：不再整段冷启动拉历史

        | 端 | 版本 | 状态 |
        |---|---|---|
        | 开发机 | 0.24.177 | 已发布 |
        | the paired iPhone | 1.0.44 (45) | 已装 |
        """
        let attributed = ChatMarkdown.attributed(source)
        let text = String(attributed.characters)

        XCTAssertFalse(text.contains("###"), "heading markers must be consumed")
        XCTAssertFalse(text.contains("|---|"), "table rule markers must be consumed")
        XCTAssertTrue(text.contains("效果"))
        XCTAssertTrue(text.contains("•"), "unordered lists need visible bullets")
        XCTAssertTrue(text.contains("打开旧会话时"))
        XCTAssertTrue(text.contains("换网重连"))
        XCTAssertTrue(text.contains(" | "), "table cells need readable separators")
        XCTAssertTrue(text.contains("开发机"))
        XCTAssertTrue(text.contains("0.24.177"))
        XCTAssertTrue(text.contains("the paired iPhone"))

        // Blocks must not collapse into one run-on line.
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertGreaterThanOrEqual(
            lines.count,
            5,
            "headings, bullets, and table rows need line breaks: \(text)"
        )
    }

    func testOversizedTextSkipsMarkdownParser() {
        let oversized = String(repeating: "a", count: ChatMarkdown.maxInlineMarkdownUTF8Count + 1)
        let attributed = ChatMarkdown.attributed("**\(oversized)**")
        // Plain fallback keeps the literal asterisks instead of applying strong emphasis.
        XCTAssertTrue(String(attributed.characters).hasPrefix("**"))
        XCTAssertFalse(nsString(attributed).hasSemiboldOrBoldFont(containing: "aa"))
    }

    func testCacheReturnsSameContent() {
        let source = "link to `code` and **bold**"
        let first = ChatMarkdown.attributed(source)
        let second = ChatMarkdown.attributed(source)
        XCTAssertEqual(String(first.characters), String(second.characters))
    }

    private func nsString(_ attributed: AttributedString) -> NSAttributedString {
        NSAttributedString(attributed)
    }
}

private extension NSAttributedString {
    func hasSemiboldOrBoldFont(containing needle: String) -> Bool {
        let full = NSRange(location: 0, length: length)
        guard full.length > 0 else { return false }
        var found = false
        enumerateAttributes(in: full, options: []) { attrs, range, stop in
            let slice = (string as NSString).substring(with: range)
            guard slice.contains(needle) else { return }
            guard let font = attrs[.font] as? UIFont else { return }
            let name = font.fontName.lowercased()
            if font.fontDescriptor.symbolicTraits.contains(.traitBold)
                || name.contains("semibold")
                || name.contains("bold")
                || name.contains("medium")
            {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
#endif
