import XCTest
@testable import Corral

/// The conversation activity cue follows the sidebar dot (owner requirement 2026-10-05).
@MainActor
final class ChatActivityStateTests: XCTestCase {
    private func resolve(
        attention: AttentionKind = .none, marker: SessionPresentation.StatusMarker?,
        live: Bool = true, connected: Bool = true
    ) -> ChatActivityState? {
        ChatActivityState.resolve(
            live: live, connected: connected, attention: attention,
            hasPrompt: false, hasRunningTool: false, marker: marker
        )
    }

    func testGreenDotShowsWorkingEvenWithoutConversationAttention() {
        XCTAssertEqual(resolve(marker: .working), .working)
        XCTAssertEqual(resolve(marker: .recent), .working)
    }

    func testYellowDotShowsWaiting() {
        XCTAssertEqual(resolve(marker: .waiting), .waiting)
    }

    func testNoDotOrRedDotShowsNothing() {
        XCTAssertNil(resolve(marker: nil))
        XCTAssertNil(resolve(marker: .unread))
    }

    func testDisconnectedShowsNothing() {
        XCTAssertNil(resolve(marker: .working, connected: false))
    }

    func testConversationWorkingStillShowsWithoutDot() {
        XCTAssertEqual(resolve(attention: .working, marker: nil), .working)
    }
}
