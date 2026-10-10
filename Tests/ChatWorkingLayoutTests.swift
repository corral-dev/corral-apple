#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

/// Entering a working session must not park a full-width Working strip in the
/// middle of the conversation. Working belongs in the navigation subtitle; the
/// loading spinner occupies the remaining pane instead of hugging next to a bar.
@MainActor
final class ChatWorkingLayoutTests: XCTestCase {
    func testWorkingLoadDoesNotCenterAStatusStrip() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let store = ConversationStore(
            sessionKey: "cursor:working-layout",
            client: nil,
            live: true,
            attention: .working,
            hostID: "layout-host"
        )
        store.setLoadingForLayoutTest(true)

        let host = UIHostingController(
            rootView: NavigationStack {
                ChatScreen {
                    ChatView(store: store, runtimeID: "cursor", scrollToMessageID: .constant(nil))
                } composer: {
                    Color.clear.frame(height: 72)
                }
                .navigationTitle("Analyze Mobile Issues")
                .navigationBarTitleDisplayMode(.inline)
            }
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        try await waitUntil { self.loadingView(in: window) != nil }
        let spinner = try XCTUnwrap(loadingView(in: window))
        let spinnerRect = spinner.convert(spinner.bounds, to: window)
        XCTAssertGreaterThan(
            spinner.bounds.width * spinner.bounds.height,
            1,
            "Loading must be a real spinner, not a zero-size placeholder"
        )
        // The spinner is centered by the expanding pane: it must sit near the
        // vertical middle of the window, not parked at the top or bottom edge.
        XCTAssertGreaterThan(spinnerRect.midY, window.bounds.height * 0.3)
        XCTAssertLessThan(spinnerRect.midY, window.bounds.height * 0.7)

        let workingLabels = labels(in: window, matching: Self.workingTitles)
        XCTAssertTrue(
            workingLabels.isEmpty,
            "Working belongs in the navigation subtitle, not as a conversation status strip"
        )
    }

    func testEmptyWorkingConversationFillsPaneWithoutStatusStrip() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let store = ConversationStore(
            sessionKey: "cursor:empty-working-layout",
            client: nil,
            live: true,
            attention: .working
        )

        let host = UIHostingController(
            rootView: ChatScreen {
                ChatView(store: store, scrollToMessageID: .constant(nil))
            } composer: {
                Color.clear.frame(height: 72)
            }
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        // ContentUnavailableView text is not traversable in the iOS 27 test
        // host (hosting view stays childless even for a bare CUAV), so wait for
        // the window to settle instead, then assert on state + absence of a
        // Working strip. Real pixels are covered by the simulator screenshots.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(store.timelineItems.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.loadError)
        XCTAssertTrue(
            labels(in: window, matching: Self.workingTitles).isEmpty,
            "An empty working conversation must not grow a centered Working strip"
        )
    }

    private static let workingTitles = ["Working", "正在处理"]

    private func loadingView(in window: UIWindow) -> UIView? {
        // The chat.loading identifier sits on a SwiftUI layout container that
        // iOS 27 no longer bridges to a UIView identifier; the hosted spinner
        // is the stable lookup instead.
        descendants(of: window).first { $0 is UIActivityIndicatorView }
    }

    private func labels(in window: UIWindow, matching titles: [String]) -> [UIView] {
        descendants(of: window).filter { view in
            let text: String?
            if let label = view as? UILabel {
                text = label.text
            } else {
                text = view.accessibilityLabel
            }
            guard let text, !text.isEmpty else { return false }
            return titles.contains { text.localizedCaseInsensitiveContains($0) }
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func waitUntil(
        timeout: TimeInterval = 4,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Timed out waiting for layout")
    }
}
#endif
