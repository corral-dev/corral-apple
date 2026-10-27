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
        XCTAssertFalse(text.contains(" | "), "table cells must not become pipe-separated prose")
        let tables = MarkdownTableProjection.layouts(in: attributed)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.alignments.count, 3)
        XCTAssertEqual(tables.first?.cells.count, 9)
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

    func testMobileTableFallsBackToRowList() {
        let source = """
        | 名称 | 状态 | 备注 |
        |:---|:---:|:---|
        | Auth | 已完成 | 支持 JWT 与 OAuth2 |
        | Payment | 进行中 | 正在对接 Stripe |
        | | | |
        """
        let attributed = ChatMarkdown.attributed(source)
        let font = UIFont.systemFont(ofSize: 17)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        text.addAttribute(.font, value: font, range: NSRange(location: 0, length: text.length))
        MobileMarkdownTable.apply(to: text, source: attributed, bodyFont: font, foreground: .label)
        let rendered = text.string
        XCTAssertTrue(rendered.contains("• Auth"), rendered)
        XCTAssertTrue(rendered.contains("  状态: 已完成"), rendered)
        XCTAssertTrue(rendered.contains("  备注: 支持 JWT 与 OAuth2"), rendered)
        XCTAssertTrue(rendered.contains("• Payment"), rendered)
        XCTAssertFalse(rendered.contains("|"), "table pipes must be gone: \(rendered)")
        XCTAssertFalse(rendered.contains("Auth  已完成"), "cells must become labeled lines: \(rendered)")
        XCTAssertEqual(rendered.components(separatedBy: "•").count - 1, 2, "empty rows are dropped: \(rendered)")
        XCTAssertEqual(rendered.components(separatedBy: "备注:").count - 1, 2, "empty cells are omitted: \(rendered)")
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0, "the fallback is plain list text")
    }

    func testMarkdownImageKeepsItsReferenceRun() {
        let source = """
        before

        ![图片渲染检查](apple/Assets/Image.png)

        after
        """
        let attributed = ChatMarkdown.attributed(source)
        let images = attributed.runs.compactMap { run -> (URL, String)? in
            guard let url = run.imageURL else { return nil }
            return (url, String(attributed[run.range].characters))
        }
        XCTAssertEqual(images.count, 1, String(attributed.characters))
        XCTAssertEqual(images.first?.0.absoluteString, "apple/Assets/Image.png")
        XCTAssertEqual(images.first?.1.trimmingCharacters(in: .whitespacesAndNewlines), "图片渲染检查")
    }

    func testSingleColumnTableBecomesBulletList() {
        let source = """
        | 名称 |
        |---|
        | Auth |
        | Payment |
        """
        let attributed = ChatMarkdown.attributed(source)
        let font = UIFont.systemFont(ofSize: 17)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        text.addAttribute(.font, value: font, range: NSRange(location: 0, length: text.length))
        MobileMarkdownTable.apply(to: text, source: attributed, bodyFont: font, foreground: .label)
        XCTAssertTrue(text.string.contains("• Auth"), text.string)
        XCTAssertTrue(text.string.contains("• Payment"), text.string)
        XCTAssertFalse(text.string.contains("|"), text.string)
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
