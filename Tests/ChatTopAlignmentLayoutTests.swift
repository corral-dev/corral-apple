#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

@MainActor
final class ChatTopAlignmentLayoutTests: XCTestCase {
    func testEdgeFollowAllowedOnlyWhenTranscriptOverflows() {
        XCTAssertFalse(ChatLatestFollowPolicy.shouldScrollToEdge(contentHeight: 200, containerHeight: 600))
        XCTAssertFalse(ChatLatestFollowPolicy.shouldScrollToEdge(contentHeight: 600, containerHeight: 600))
        XCTAssertTrue(ChatLatestFollowPolicy.shouldScrollToEdge(contentHeight: 800, containerHeight: 600))
        XCTAssertFalse(ChatLatestFollowPolicy.shouldScrollToEdge(contentHeight: 0, containerHeight: 600))
        XCTAssertFalse(ChatLatestFollowPolicy.shouldScrollToEdge(contentHeight: 200, containerHeight: 0))
    }

    /// WeChat-style: a two-bubble transcript rests at the top and the empty
    /// space stays below — never a giant blank band above the first bubble.
    func testShortTranscriptRestsAtTopWithEmptySpaceBelow() async throws {
        try await assertShortTranscriptRestsAtTop(live: false)
    }

    func testAsyncShortWorkingTranscriptRestsAtTop() async throws {
        try await assertShortTranscriptRestsAtTop(live: true)
    }

    private func assertShortTranscriptRestsAtTop(live: Bool) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-top-align-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ConversationTailCache.directoryOverride = scratch
        defer {
            ConversationTailCache.directoryOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }

        let snapshot = ConversationTailSnapshot(
                hostID: "layout-host",
                sessionKey: "pi:top-align-layout",
                messages: [
                    RichMessage(seq: 40, role: "user", text: "Top aligned first bubble.", delivery: .sent),
                    RichMessage(seq: 41, role: "assistant", text: "Short reply.", delivery: .sent),
                ],
                oldestSequence: 40,
                newestSequence: 41,
                hasMoreHistory: false,
                generation: 1,
                savedAt: Date()
            )
        if !live { ConversationTailCache.save(snapshot) }
        let store = ConversationStore(
            sessionKey: "pi:top-align-layout",
            client: nil,
            live: live,
            attention: live ? .working : .none,
            hostID: "layout-host"
        )

        var targetID: String?
        let host = UIHostingController(
            rootView: NavigationStack {
                ChatScreen {
                    ChatView(store: store, scrollToMessageID: Binding(
                        get: { targetID },
                        set: { targetID = $0 }
                    ))
                } composer: {
                    Color.clear.frame(height: 72)
                }
                .navigationTitle("Top alignment layout")
                .navigationBarTitleDisplayMode(.inline)
            }
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        if live {
            // Mount empty first, then let a live snapshot introduce the bubbles
            // and Working cue together, as on the real open path.
            try await Task.sleep(for: .milliseconds(100))
            ConversationTailCache.save(snapshot)
            store.loadPersistedTail()
        }

        let deadline = Date().addingTimeInterval(8)
        var message: UIView?
        while Date() < deadline {
            message = descendants(of: window).compactMap { $0 as? UITextView }.first {
                !$0.isEditable && $0.text.contains("Top aligned first bubble")
            }
            if message != nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(400))
        let firstMessage = try XCTUnwrap(message)
        let scroll = try XCTUnwrap(descendants(of: window).compactMap { $0 as? UIScrollView }
            .first(where: { !($0 is UITextView) }))
        let viewport = scroll.convert(scroll.bounds, to: window)
        let messageRect = firstMessage.convert(firstMessage.bounds, to: window)
        let expectedTop = viewport.minY + scroll.adjustedContentInset.top
            + MessageBubbleLayout.bubbleVerticalPadding / 2
        XCTAssertEqual(
            messageRect.minY, expectedTop, accuracy: Space.base,
            "Short bubbles must sit at the viewport's top inset, including live asynchronous entry"
        )
        XCTAssertEqual(
            scroll.contentOffset.y, -scroll.adjustedContentInset.top, accuracy: 2,
            "A short transcript must keep its top offset instead of an explicit latest-item offset"
        )
    }

    /// Opening a long transcript whose rows vary wildly in height (long replies
    /// next to one-line prompts) must settle on the real last line: the lazy
    /// stack's first bottom landing uses estimated row heights, and the
    /// 2026-10-05 defect left a blank band under the latest message.
    func testLongMixedTranscriptOpensOnTrueBottom() async throws {
        try await assertLongTranscriptOpensOnTrueBottom(asyncArrival: false, widthChange: false)
    }

    func testAsyncLongTranscriptOpensOnTrueBottom() async throws {
        try await assertLongTranscriptOpensOnTrueBottom(asyncArrival: true, widthChange: false)
    }

    /// A Mac split pane is resized while it opens (another pane joins), so every
    /// realized row reflows after the first bottom landing.
    func testLongTranscriptStaysOnTrueBottomAcrossWidthChange() async throws {
        try await assertLongTranscriptOpensOnTrueBottom(asyncArrival: false, widthChange: true)
    }

    private func assertLongTranscriptOpensOnTrueBottom(asyncArrival: Bool, widthChange: Bool) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-open-bottom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ConversationTailCache.directoryOverride = scratch
        defer {
            ConversationTailCache.directoryOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }

        let longReply = (1...24).map { "- Line \($0) of a long reply that wraps across the bubble width." }
            .joined(separator: "\n")
        var messages: [RichMessage] = []
        for index in 0..<60 {
            let seq = 100 + index * 2
            messages.append(RichMessage(seq: seq, role: "user", text: "Short \(index)", delivery: .sent))
            let reply = index.isMultiple(of: 3) ? longReply : "Ok \(index)."
            messages.append(RichMessage(seq: seq + 1, role: "assistant", text: reply, delivery: .sent))
        }
        let lastSeq = 100 + 60 * 2
        messages.append(RichMessage(
            seq: lastSeq, role: "assistant",
            text: "## Summary\n\n\(longReply)\n\nFinal bottom marker line.",
            delivery: .sent
        ))
        let snapshot = ConversationTailSnapshot(
            hostID: "layout-host",
            sessionKey: "pi:open-bottom-layout",
            messages: messages,
            oldestSequence: 100,
            newestSequence: lastSeq,
            hasMoreHistory: false,
            generation: 1,
            savedAt: Date()
        )
        if !asyncArrival { ConversationTailCache.save(snapshot) }
        let store = ConversationStore(
            sessionKey: "pi:open-bottom-layout",
            client: nil,
            live: false,
            attention: .none,
            hostID: "layout-host"
        )

        let host = UIHostingController(
            rootView: NavigationStack {
                ChatScreen {
                    ChatView(store: store)
                } composer: {
                    Color.clear.frame(height: 72)
                }
                .navigationTitle("Open bottom layout")
                .navigationBarTitleDisplayMode(.inline)
            }
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        if asyncArrival {
            try await Task.sleep(for: .milliseconds(100))
            ConversationTailCache.save(snapshot)
            store.loadPersistedTail()
        }

        let deadline = Date().addingTimeInterval(8)
        var marker: UIView?
        while Date() < deadline {
            marker = finalMarker(in: window)
            if marker != nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        if widthChange {
            try await Task.sleep(for: .milliseconds(300))
            let full = window.bounds
            for width in stride(from: full.width, through: full.width * 0.6, by: -full.width * 0.05) {
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: full.height)
                try await Task.sleep(for: .milliseconds(16))
            }
            try await Task.sleep(for: .milliseconds(300))
            for width in stride(from: full.width * 0.6, through: full.width, by: full.width * 0.05) {
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: full.height)
                try await Task.sleep(for: .milliseconds(16))
            }
            host.view.frame = full
        }
        try await Task.sleep(for: .milliseconds(800))
        let lastMessage = try XCTUnwrap(finalMarker(in: window), "The latest message must be on screen after opening")
        let scroll = try XCTUnwrap(descendants(of: window).compactMap { $0 as? UIScrollView }
            .first(where: { !($0 is UITextView) }))
        let viewport = scroll.convert(scroll.bounds, to: window)
        let visibleBottom = viewport.maxY - scroll.adjustedContentInset.bottom
        let messageRect = lastMessage.convert(lastMessage.bounds, to: window)
        XCTAssertLessThanOrEqual(messageRect.maxY, visibleBottom + 1, "The latest line must not sit under the composer")
        XCTAssertLessThanOrEqual(
            visibleBottom - messageRect.maxY, Space.base * 3,
            "Opening must not leave a blank band under the latest message"
        )
        let maxOffset = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        XCTAssertEqual(scroll.contentOffset.y, maxOffset, accuracy: 2, "Opening must rest on the real bottom edge")
    }

    private func finalMarker(in window: UIWindow) -> UIView? {
        descendants(of: window).compactMap { $0 as? UITextView }.first {
            !$0.isEditable && $0.text.contains("Final bottom marker line")
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
#endif
