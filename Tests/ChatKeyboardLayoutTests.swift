#if os(iOS)
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Corral

/// Runs the production chat, composer and layout in a real UIWindow. Keyboard
/// presentation uses the responder API; it never moves or clicks the Mac pointer.
@MainActor
final class ChatKeyboardLayoutTests: XCTestCase {
    private let keyboard = TestKeyboardObserver()

    func testKeyboardCycleTypingMultilineAndHistoryNavigation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let fixture = KeyboardFixture()
        await fixture.store.handle(RemoteEvent(channel: "session:keyboard-test", data: [
            "messages": (1...30).map {
                ["seq": $0, "role": $0.isMultiple(of: 2) ? "assistant" : "user",
                 "text": "Message \($0). Keyboard layout must preserve a readable conversation."] as [String: Any]
            }
        ]))
        let host = UIHostingController(rootView: KeyboardFixtureView(fixture: fixture))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        try await waitUntil { self.editableInput(in: window) != nil }
        let input = try XCTUnwrap(editableInput(in: window))
        let keyInput = try XCTUnwrap(input as? any UIKeyInput)
        let restingY = input.convert(input.bounds, to: window).maxY
        XCTAssertGreaterThan(restingY, window.bounds.height * 0.7)

        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            XCTAssertTrue(input.becomeFirstResponder())
            try await waitUntil {
                let rect = input.convert(input.bounds, to: window)
                return rect.maxY < restingY - 100 && rect.minY > window.safeAreaInsets.top + 44
            }
            try await settle()
            assertComposerIsAboveKeyboard(input, window: window)
            let conversationScroll = try XCTUnwrap(conversationScroll(in: window))
            XCTAssertLessThan(distanceToBottom(conversationScroll), 44,
                              "The latest message must remain visible when the keyboard appears")
            keyInput.insertText("Keyboard accepts input. ")
            try await waitUntil { fixture.text.contains("Keyboard accepts input.") }
            XCTAssertTrue(input.isFirstResponder)

            let oneLineHeight = input.bounds.height
            keyInput.insertText(String(repeating: "More text wraps naturally. ", count: 35))
            try await waitUntil { input.bounds.height > oneLineHeight + 20 }
            assertComposerIsAboveKeyboard(input, window: window)
            XCTAssertLessThan(input.bounds.height, window.bounds.height * 0.4)
            try await settle()
            XCTAssertLessThan(distanceToBottom(conversationScroll), 44,
                              "Multiline growth must keep the latest message above the composer")
            let captureName = "keyboard-\(style == .light ? "light" : "dark")"
            capture(window, name: captureName)
            print("KEYBOARD_SCREENSHOT_READY \(captureName)")
            try await Task.sleep(for: .seconds(2))

            // Programmatic history selection exercises the same production route
            // as selecting a prompt from the navigation sheet.
            fixture.targetID = "message-3"
            // Outlast the jump: glide plus its final settle (~0.55 s).
            try await Task.sleep(for: .milliseconds(1200))
            let scroll = conversationScroll
            let historyOffset = scroll.contentOffset.y
            await fixture.store.handle(RemoteEvent(channel: "session:keyboard-test", data: [
                "message": ["seq": 31 + style.rawValue, "role": "assistant", "text": "New background reply."]
            ]))
            try await settle()
            XCTAssertEqual(scroll.contentOffset.y, historyOffset, accuracy: 10,
                           "Incoming content must not steal the history reading position")

            fixture.send("A deliberate send restores the latest messages")
            try await waitUntil { self.distanceToBottom(scroll) < 44 }

            window.endEditing(true)
            try await waitUntil { input.convert(input.bounds, to: window).maxY > restingY - 5 }
            XCTAssertFalse(input.isFirstResponder)
            fixture.text = ""
            try await settle()
        }
    }

    func testInitialMessageMarginsRemainStableAfterScrolling() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let fixture = KeyboardFixture()
        let host = UIHostingController(rootView: KeyboardFixtureView(fixture: fixture))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await settle()
        await fixture.store.handle(RemoteEvent(channel: "session:keyboard-test", data: [
            "messages": (1...30).map {
                ["seq": $0, "role": "assistant",
                 "text": "Margin message \($0). " + String(repeating: "The conversation must keep equal page margins. ", count: $0 % 4 + 1)] as [String: Any]
            }
        ]))
        try await waitUntil { self.conversationScroll(in: window) != nil }
        try await settle()
        let scroll = try XCTUnwrap(conversationScroll(in: window))
        var referenceMinX: CGFloat?
        for stage in ["initial", "history", "latest"] {
            if stage == "history" { fixture.targetID = "message-3" }
            if stage == "latest" { fixture.scrollToLatestRequest += 1 }
            try await settle()
            let texts = descendants(of: scroll).compactMap { $0 as? UITextView }.filter {
                !$0.isEditable && $0.text.hasPrefix("Margin message") &&
                $0.convert($0.bounds, to: window).intersects(scroll.convert(scroll.bounds, to: window))
            }
            XCTAssertFalse(texts.isEmpty)
            print("MARGIN_STAGE \(stage) offset=\(scroll.contentOffset) size=\(scroll.contentSize) bounds=\(scroll.bounds)")
            for text in texts {
                let rect = text.convert(text.bounds, to: window)
                print("MARGIN_TEXT \(stage) \(rect)")
                // Stability across stages is the contract (Initial conversation
                // margins): entering, history selection and latest must agree —
                // not an absolute constant that drifts with bubble padding.
                if let referenceMinX {
                    XCTAssertEqual(rect.minX, referenceMinX, accuracy: 1, "Left margin drifts at \(stage)")
                } else {
                    referenceMinX = rect.minX
                }
                // Keep symmetric page margins: the text must clear both edges.
                XCTAssertGreaterThan(rect.minX, Space.base - 1, "Left margin at \(stage)")
                XCTAssertLessThanOrEqual(rect.maxX, window.bounds.width - Space.base + 1)
            }
            capture(window, name: "margins-\(stage)")
        }
    }

    func testShortConversationStaysAtTopOverKeyboard() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let fixture = KeyboardFixture()
        await fixture.store.handle(RemoteEvent(channel: "session:keyboard-test", data: [
            "messages": [["seq": 1, "role": "assistant", "text": "Short history."]]
        ]))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: KeyboardFixtureView(fixture: fixture))
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await settle()
        let input = try XCTUnwrap(editableInput(in: window))
        let message = try XCTUnwrap(descendants(of: window).compactMap { $0 as? UITextView }
            .first { !$0.isEditable && $0.text == "Short history." })
        let restingMessage = message.convert(message.bounds, to: window)
        let restingInput = input.convert(input.bounds, to: window)
        capture(window, name: "short-history-resting")
        // WeChat-style top alignment: a one-bubble transcript rests at the top
        // with the empty space below it (user ruling 2026-09-14) — never sunk
        // to the composer with a blank band above.
        XCTAssertLessThan(
            restingMessage.minY,
            window.bounds.height * 0.45,
            "A short transcript must rest at the top, not sink to the composer"
        )
        XCTAssertTrue(input.becomeFirstResponder())
        try await waitUntil { input.convert(input.bounds, to: window).maxY < restingInput.maxY - 100 }
        try await settle()
        // The keyboard shrinks the viewport but must not cover the message or
        // shove it into the status bar: it stays where it was, above the keys.
        let raisedMessage = message.convert(message.bounds, to: window)
        XCTAssertEqual(raisedMessage.minY, restingMessage.minY, accuracy: 3)
        XCTAssertEqual(raisedMessage.maxY, restingMessage.maxY, accuracy: 3)
        XCTAssertGreaterThan(raisedMessage.minY, window.safeAreaInsets.top + 44)
          let raisedSurface = composerSurfaceRect(from: input, in: window)
          XCTAssertLessThan(raisedMessage.maxY, raisedSurface.minY)
        // Left edge inherits the scroll page margin plus the bubble's own
        // horizontal padding — assert stability across the keyboard cycle,
        // not an absolute constant (see Initial conversation margins).
        assertComposerIsAboveKeyboard(input, window: window)
        capture(window, name: "short-history-keyboard")
        window.endEditing(true)
        try await waitUntil { input.convert(input.bounds, to: window).maxY > restingInput.maxY - 5 }
        try await settle()
        XCTAssertEqual(message.convert(message.bounds, to: window).maxY, restingMessage.maxY, accuracy: 3)
        XCTAssertEqual(message.convert(message.bounds, to: window).minX, restingMessage.minX, accuracy: 1)

        await fixture.store.handle(RemoteEvent(channel: "session:keyboard-test", data: [
            "message": ["seq": 2, "role": "assistant", "text": String(repeating: "History becomes scrollable when the keyboard opens. ", count: 12)]
        ]))
        try await settle()
        let last = try XCTUnwrap(descendants(of: window).compactMap { $0 as? UITextView }
            .first { !$0.isEditable && $0.text.hasPrefix("History becomes") })
        let scroll = try XCTUnwrap(descendants(of: window).compactMap { $0 as? UIScrollView }
            .first { !($0 is UITextView) && $0.contentSize.height > 200 })
        XCTAssertLessThan(scroll.contentSize.height,
                          restingInput.minY - window.safeAreaInsets.top - 44)
        XCTAssertTrue(input.becomeFirstResponder())
        try await waitUntil { input.convert(input.bounds, to: window).maxY < restingInput.maxY - 100 }
        try await settle()
        XCTAssertGreaterThan(scroll.contentSize.height,
                             scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom)
        // Top-aligned transcript: the new tail grows downward, so its last line
        // may sit below the keyboard-shrunk viewport until the user scrolls.
        // What matters is no content is stranded above the viewport: the first
        // bubble stays reachable and the tail's top is visible.
        let lastRect = last.convert(last.bounds, to: window)
        let surfaceTop = composerSurfaceRect(from: input, in: window).minY
        XCTAssertLessThan(lastRect.minY, surfaceTop)
        XCTAssertGreaterThan(lastRect.maxY, window.safeAreaInsets.top + 44)
        capture(window, name: "short-history-now-scrollable")

    }

    /// Keyboard returns to latest (owner requirement 2026-10-13): every time the
    /// keyboard comes up, the newest content sits fully above the composer — for
    /// a transcript that overflows only once the keyboard shrinks the viewport,
    /// for a long one read from history (including focus while a Your prompts
    /// jump is still settling), with the Working cue and a reply arriving while
    /// the keyboard rises, and on every repeated cycle.
    func testKeyboardRevealsLatestOnEveryCycle() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        for (scenario, count) in [("medium", 6), ("jumpSettling", 30), ("history", 30), ("streaming", 30)] {
            let fixture = KeyboardFixture()
            if scenario == "streaming" { fixture.marker = .working }
            await fixture.store.handle(RemoteEvent(channel: "session:keyboard-test", data: [
                "messages": (1...count).map {
                    ["seq": $0, "role": $0.isMultiple(of: 2) ? "assistant" : "user",
                     "text": "Reveal \($0). The newest message must clear the composer whenever the keyboard opens."
                        + ($0 % 3 == 1 && $0 != count
                           ? String(repeating: "\nA tall reply whose height a lazy stack can only estimate.", count: $0 % 5 * 4)
                           : "")] as [String: Any]
                }
            ]))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: KeyboardFixtureView(fixture: fixture))
            window.makeKeyAndVisible()
            defer {
                window.endEditing(true)
                window.isHidden = true
                window.rootViewController = nil
                previousWindow?.makeKeyAndVisible()
            }
            try await waitUntil { self.editableInput(in: window) != nil }
            try await settle()
            let input = try XCTUnwrap(editableInput(in: window))
            let restingInput = input.convert(input.bounds, to: window)
            for cycle in 1...3 {
                switch scenario {
                case "jumpSettling":
                    // Focus lands while the jump's delayed settle is still pending.
                    fixture.targetID = "message-3"
                    try await Task.sleep(for: .milliseconds(150))
                case "history":
                    fixture.targetID = "message-3"
                    try await Task.sleep(for: .seconds(1.5))
                default:
                    break
                }
                XCTAssertTrue(input.becomeFirstResponder())
                let latestSeq = scenario == "streaming" ? count + cycle : count
                if scenario == "streaming" {
                    try await Task.sleep(for: .milliseconds(60 * cycle))
                    await fixture.store.handle(RemoteEvent(channel: "session:keyboard-test", data: [
                        "message": ["seq": latestSeq, "role": "assistant",
                                    "text": "Reveal \(latestSeq). A reply arriving " + String(repeating: "while the keyboard rises. ", count: 20)]
                    ]))
                }
                try await waitUntil { input.convert(input.bounds, to: window).maxY < restingInput.maxY - 100 }
                // Outlast the jump glide so a late settle would show.
                try await Task.sleep(for: .seconds(1))
                let surfaceTop = composerSurfaceRect(from: input, in: window).minY
                let last = descendants(of: window).compactMap { $0 as? UITextView }
                    .first { !$0.isEditable && $0.text.hasPrefix("Reveal \(latestSeq).") }
                let lastRect = last.map { $0.convert($0.bounds, to: window) } ?? .null
                print("KEYBOARD_REVEAL \(scenario) cycle=\(cycle) last=\(lastRect) surfaceTop=\(surfaceTop)")
                capture(window, name: "reveal-\(scenario)-\(cycle)")
                assertComposerIsAboveKeyboard(input, window: window)
                XCTAssertNotNil(last, "\(scenario) cycle \(cycle): latest message is not realized")
                XCTAssertLessThanOrEqual(lastRect.maxY, surfaceTop + 1,
                                         "\(scenario) cycle \(cycle): latest message hidden behind the composer/keyboard")
                XCTAssertGreaterThan(lastRect.minY, window.safeAreaInsets.top + 44,
                                     "\(scenario) cycle \(cycle): latest message pushed under the navigation bar")
                window.endEditing(true)
                try await waitUntil { input.convert(input.bounds, to: window).maxY > restingInput.maxY - 5 }
                try await settle()
            }
        }
    }

    private func assertComposerIsAboveKeyboard(_ input: UIView, window: UIWindow,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let inputRect = input.convert(input.bounds, to: window)
        let surfaceRect = composerSurfaceRect(from: input, in: window)
        let keyboard = window.convert(keyboard.frame, from: window.screen.coordinateSpace)
        XCTAssertGreaterThan(keyboard.height, 100, "A software keyboard must actually be visible", file: file, line: line)
        XCTAssertGreaterThan(surfaceRect.minY, window.safeAreaInsets.top + 44, file: file, line: line)
        XCTAssertLessThanOrEqual(surfaceRect.maxY, keyboard.minY + 1, file: file, line: line)
        XCTAssertLessThan(keyboard.minY - surfaceRect.maxY, 24, file: file, line: line)
        XCTAssertLessThan(inputRect.maxY, surfaceRect.maxY - 8, file: file, line: line)
        XCTAssertGreaterThan(inputRect.minY, surfaceRect.minY - 1, file: file, line: line)
    }

    /// The floating card is wider than the text field and includes the action row
    /// below it. Prefer the marked surface; otherwise walk ancestors and stop
    /// before a screen-filling container.
    private func composerSurfaceRect(from input: UIView, in window: UIWindow) -> CGRect {
        if let surface = descendants(of: window).first(where: {
            $0.accessibilityIdentifier == "composer.surface" && $0.bounds.height > 40
        }) {
            return surface.convert(surface.bounds, to: window)
        }
        let inputRect = input.convert(input.bounds, to: window)
        var view: UIView? = input.superview
        var candidate = inputRect
        while let current = view, current !== window {
            let rect = current.convert(current.bounds, to: window)
            if rect.width >= window.bounds.width - 4 { break }
            if rect.width >= inputRect.width,
               rect.maxY >= inputRect.maxY,
               rect.minY >= window.bounds.height * 0.3 {
                candidate = rect
            }
            view = current.superview
        }
        return candidate
    }

    private func conversationScroll(in view: UIView) -> UIScrollView? {
        descendants(of: view).compactMap { $0 as? UIScrollView }
            .first { !($0 is UITextView) && $0.contentSize.height > $0.bounds.height * 2 }
    }

    private func distanceToBottom(_ scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom
            - scroll.contentOffset.y - scroll.bounds.height
    }

    private func editableInput(in view: UIView) -> UIView? {
        descendants(of: view).first {
            if let text = $0 as? UITextView { return text.isEditable }
            return $0 is UITextField
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        guard condition() else {
            XCTFail("Runtime layout/input did not settle before the deadline", file: file, line: line)
            throw TestFailure.timeout
        }
    }

    private enum TestFailure: Error { case timeout }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class TestKeyboardObserver: NSObject {
    var frame = CGRect.zero

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc private func changed(_ notification: Notification) {
        if let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            frame = value.cgRectValue
        }
    }
}

@MainActor @Observable
private final class KeyboardFixture {
    let store = ConversationStore(sessionKey: "keyboard-test", client: nil, live: false)
    var text = ""
    var attachments: [DraftImageAttachment] = []
    var targetID: String?
    var scrollToLatestRequest = 0
    var marker: SessionPresentation.StatusMarker?

    func send(_ text: String) {
        _ = store.enqueueLocalUser(text)
        scrollToLatestRequest += 1
    }
}

private struct KeyboardFixtureView: View {
    @Bindable var fixture: KeyboardFixture

    var body: some View {
        NavigationStack {
            ChatScreen {
                ChatView(store: fixture.store, sessionMarker: fixture.marker, scrollToLatestRequest: fixture.scrollToLatestRequest, scrollToMessageID: $fixture.targetID)
            } composer: {
                // Same focus route as SessionDetailView: the keyboard coming up
                // requests latest.
                ComposerBar(text: $fixture.text, attachments: $fixture.attachments, onFocusChange: { focused in
                    if focused { fixture.scrollToLatestRequest += 1 }
                }) { text, _ in
                    fixture.send(text)
                }
            }
            .navigationTitle("Keyboard layout")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
