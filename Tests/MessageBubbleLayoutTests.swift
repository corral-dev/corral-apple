#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

@MainActor
final class MessageBubbleLayoutTests: XCTestCase {
    func testAssistantBubbleFillsContentWidthNotFixed300() {
        let text = String(repeating: "这段助手回复应该铺满内容区，左右只留对话页边距。", count: 6)
        let host = UIHostingController(
            rootView: MessageBubbleView(message: RichMessage(seq: 1, role: "assistant", text: text))
        )
        let contentWidth: CGFloat = 358
        let size = host.sizeThatFits(in: CGSize(width: contentWidth, height: 2000))
        XCTAssertEqual(
            size.width,
            contentWidth,
            accuracy: 1,
            "助手气泡应铺满内容区，而不是卡在固定窄宽"
        )
        XCTAssertGreaterThan(size.width, 300)
    }

    func testLongMessageBubbleTallerThanSingleLine() {
        let text = String(repeating: "多行消息必须完整换行显示，不能只剩一行。", count: 6)
        let host = UIHostingController(
            rootView: MessageBubbleView(message: RichMessage(seq: 2, role: "assistant", text: text))
        )
        let size = host.sizeThatFits(in: CGSize(width: 358, height: 4000))
        // One body line + vertical padding is well under ~50pt; wrapped copy is taller.
        XCTAssertGreaterThan(
            size.height,
            56,
            "SelectableAttributedText must size to wrapped height inside ScrollView parents"
        )
    }

    func testShortSelectableTextHugsContentWidth() {
        let host = UIHostingController(
            rootView: SelectableAttributedText(
                attributed: AttributedString("ok"),
                foreground: .white,
                tint: .white,
                fontStyle: .bubbleBody
            )
        )
        let size = host.sizeThatFits(in: CGSize(width: 358, height: 2000))
        XCTAssertLessThan(
            size.width,
            80,
            "短文案应按内容收紧，sizeThatFits 不得直接回传提议宽度"
        )
    }

    func testShortUserBubbleHugsInsteadOfStretchingRow() {
        // Regression: wrapping bubble text in GeometryReader + maxWidth infinity
        // stretched "可以" across the conversation row like a full-width button.
        // MessageBubbleView's HStack includes a leading Spacer, so the *row* is
        // full width by design — assert on the text view and overall height.
        let textHost = UIHostingController(
            rootView: SelectableAttributedText(
                attributed: AttributedString("可以"),
                foreground: .white,
                tint: .white,
                fontStyle: .bubbleBody,
                maxHeight: MessageBubbleLayout.maxTextHeight(screenHeight: 852)
            )
        )
        let textSize = textHost.sizeThatFits(in: CGSize(width: 358, height: 2000))
        XCTAssertLessThan(
            textSize.width,
            80,
            "短用户文案必须按内容收紧，不得回传提议宽度"
        )
        XCTAssertLessThan(textSize.height, 48, "短文案高度应贴近一行")

        let rowHost = UIHostingController(
            rootView: MessageBubbleView(message: RichMessage(seq: 3, role: "user", text: "可以"))
        )
        let rowSize = rowHost.sizeThatFits(in: CGSize(width: 358, height: 2000))
        XCTAssertLessThan(rowSize.height, 80, "短用户气泡行高不得被 GeometryReader 撑高")
    }

    /// The bubble frame must match the text view's own layout. A taller frame
    /// shows as a blank band under the reply (2026-10-05 Mac defect, where
    /// `boundingRect` sizing ran ahead of the drawn layout on long Markdown).
    func testBubbleFrameMatchesTextLayoutForMarkdownReplies() throws {
        let reply = """
        **修复**：列表数据本身保证不重复，侧栏分组时每个会话只归第一个认领它的组；之前缓存在本机的旧列表读出时也会先去重。
        - **Mac**：已修复，0.3.4 已装到"应用程序"，连接正常，分组显示正确。
        - **iPhone**：手机和 Mac 共用这部分代码，同一处修复覆盖两端（[装包页](https://example.com/a/corral)）。
        - **终端界面**：不受影响。开发机加会话进组时会把它从其他组移走、去掉重复成员。

        参考：[Apple 开发者论坛：列表里多个可展开组同时移动时行错位](https://developer.apple.com/forums/thread/742008)
        """
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 2400))
        for width in stride(from: CGFloat(240), through: 420, by: 7) {
            let host = UIHostingController(rootView: SelectableAttributedText(
                attributed: ChatMarkdown.attributed(reply), fontStyle: .bubbleBody
            ))
            window.rootViewController = host
            window.isHidden = false
            let size = host.sizeThatFits(in: CGSize(width: width, height: 2400))
            host.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
            host.view.layoutIfNeeded()
            let textView = try XCTUnwrap(Self.descendants(of: host.view).compactMap { $0 as? UITextView }.first)
            let drawn = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
            XCTAssertEqual(textView.bounds.height, drawn, accuracy: 2, "Bubble frame must match drawn text at width \(width)")
        }
        window.isHidden = true
    }

    private static func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testOverlongBubbleCapsAtFiftyPercentScreenHeight() {
        let text = String(repeating: "超长消息应在气泡内滚动，而不是占满整条时间线。\n", count: 120)
        let host = UIHostingController(
            rootView: MessageBubbleView(message: RichMessage(seq: 4, role: "assistant", text: text))
        )
        let screenHeight: CGFloat = 852
        let size = host.sizeThatFits(in: CGSize(width: 358, height: 20_000))
        // Production uses the live screen; sizeThatFits here still applies that same
        // live cap. Assert against the live screen so the test matches runtime.
        let liveCap = MessageBubbleLayout.maxTextHeight() + MessageBubbleLayout.bubbleVerticalPadding
        XCTAssertLessThanOrEqual(
            size.height,
            liveCap + 2,
            "超长气泡高度不得超过屏高 50%（含气泡上下内边距）"
        )
        XCTAssertGreaterThan(size.height, 100, "封顶后仍应保留可读高度")
        XCTAssertEqual(
            MessageBubbleLayout.maxTextHeight(screenHeight: screenHeight),
            max(screenHeight * 0.5 - 24, 44),
            accuracy: 0.5
        )
    }

    func testAssistantBubbleContrastsGroupedPageInLightMode() {
        // Chat page uses systemGroupedBackground. Plain secondarySystemBackground
        // resolves to the same gray in light mode — bubbles vanish. Grouped secondary
        // is white-on-gray in light and stays elevated in dark.
        let light = UITraitCollection(userInterfaceStyle: .light)
        let page = UIColor.systemGroupedBackground.resolvedColor(with: light)
        let plainSecondary = UIColor.secondarySystemBackground.resolvedColor(with: light)
        let groupedSecondary = UIColor.secondarySystemGroupedBackground.resolvedColor(with: light)
        let palette = UIColor(Palette.assistantBubble).resolvedColor(with: light)

        XCTAssertEqual(
            plainSecondary.cgColor,
            page.cgColor,
            "Sanity: plain secondary matches grouped page in light (the old bug)"
        )
        XCTAssertNotEqual(
            groupedSecondary.cgColor,
            page.cgColor,
            "Grouped secondary must contrast the chat page in light mode"
        )
        XCTAssertEqual(
            palette.cgColor,
            groupedSecondary.cgColor,
            "Palette.assistantBubble must use secondarySystemGroupedBackground"
        )
    }
}
#endif
