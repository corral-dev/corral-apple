#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

/// Exercise the current SwiftUI scrolling surface, rather than the removed
/// UIKit interruption helper. Physical one-tap deceleration remains a separate check.
@MainActor
final class ChatScrollMomentumTests: XCTestCase {
    @Observable final class Fixture {
        var first = 40
        var request = 0
        var target: String?
    }

    func testPrependingPreservesReadingPositionAndLatestRemainsReachable() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let fixture = Fixture()
        let host = UIHostingController(rootView: FixtureView(fixture: fixture))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.max { $0.bounds.height < $1.bounds.height })
        fixture.target = "message-45"
        try await Task.sleep(for: .milliseconds(500))
        let before = scroll.contentOffset.y
        fixture.first = 20
        try await Task.sleep(for: .milliseconds(700))
        // Every prepended row is 80 points + the production stack's 4-point gap.
        XCTAssertEqual(scroll.contentOffset.y - before, 20 * 84, accuracy: 8)
        fixture.request += 1
        try await Task.sleep(for: .milliseconds(700))
        let remaining = scroll.contentSize.height + scroll.adjustedContentInset.bottom
            - scroll.contentOffset.y - scroll.bounds.height
        XCTAssertLessThanOrEqual(abs(remaining), 25)
    }

    struct FixtureView: View {
        @Bindable var fixture: Fixture
        var body: some View {
            ChatScrollView(scrollToLatestRequest: fixture.request,
                           latestID: "message-79", scrollToMessageID: $fixture.target,
                           header: { EmptyView() }) {
                ForEach(fixture.first..<80, id: \.self) { index in
                    Text("Message \(index)").frame(maxWidth: .infinity).frame(height: 80)
                        .id("message-\(index)")
                }
            }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
#endif
