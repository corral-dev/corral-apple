import XCTest
@testable import Corral

@MainActor
final class SessionHeaderPresentationTests: XCTestCase {
    func testEmptyTitleUsesUntitledFallbackNotOpaqueKey() {
        XCTAssertEqual(
            SessionHeaderPresentation.title(from: "   "),
            String(localized: "session.detail.untitled")
        )
        XCTAssertEqual(
            SessionHeaderPresentation.title(from: "  Fix login  "),
            "Fix login"
        )
    }

    func testConnectedWorkingIsRunningWithoutBrandDotSemantics() {
        let model = SessionHeaderPresentation.make(
            rawTitle: "Long conversation title",
            runtime: "codex",
            live: true,
            attention: .working,
            conversationReady: true,
            connection: .connected,
            showsTerminal: false
        )
        XCTAssertEqual(model.assistantName, "Codex")
        XCTAssertEqual(model.state, .running)
        XCTAssertEqual(model.state.markerColor, Palette.attentionWorking)
    }

    func testWaitingUsesReplyState() {
        let state = SessionHeaderPresentation.resolveState(
            live: true,
            attention: .waiting,
            conversationReady: true,
            connection: .connected,
            showsTerminal: false
        )
        XCTAssertEqual(state, .needsReply)
        XCTAssertEqual(state.markerColor, Palette.attentionWaiting)
    }

    func testStaleWorkingDoesNotRemainRunningWhenDisconnected() {
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: true,
                attention: .working,
                conversationReady: true,
                connection: .disconnected,
                showsTerminal: false
            ),
            .offline
        )
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: true,
                attention: .working,
                conversationReady: true,
                connection: .connecting,
                showsTerminal: false
            ),
            .connecting
        )
    }

    func testEndedStaysEndedOffline() {
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: false,
                attention: .working,
                conversationReady: false,
                connection: .disconnected,
                showsTerminal: false
            ),
            .ended
        )
    }

    func testConnectedWithoutFreshConversationIsUpdating() {
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: true,
                attention: .working,
                conversationReady: false,
                connection: .connected,
                showsTerminal: false
            ),
            .updating
        )
    }

    func testIdleLiveSessionIsReadyAndUnreadIsNotAHeaderState() {
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: true,
                attention: .none,
                conversationReady: true,
                connection: .connected,
                showsTerminal: false
            ),
            .ready
        )
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: true,
                attention: .unread,
                conversationReady: true,
                connection: .connected,
                showsTerminal: false
            ),
            .ready
        )
    }

    func testNotLiveConnectedStillRunsWhenAttentionIsWorking() {
        // Stale list live=false must not hide a fresh working signal.
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: false,
                attention: .working,
                conversationReady: true,
                connection: .connected,
                showsTerminal: false
            ),
            .running
        )
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: false,
                attention: .waiting,
                conversationReady: true,
                connection: .connected,
                showsTerminal: false
            ),
            .needsReply
        )
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: false,
                attention: .unread,
                conversationReady: true,
                connection: .connected,
                showsTerminal: false
            ),
            .ended
        )
    }

    func testHostedKeepaliveIsReadyWhenLiveFlagMissing() {
        // Detail view ORs hosted into live; presentation itself only sees the OR result.
        XCTAssertEqual(
            SessionHeaderPresentation.resolveState(
                live: true,
                attention: .unread,
                conversationReady: true,
                connection: .connected,
                showsTerminal: false
            ),
            .ready
        )
    }

    func testUnknownRuntimeNameStaysVisible() {
        let model = SessionHeaderPresentation.make(
            rawTitle: "Task",
            runtime: "custom-bot",
            live: true,
            attention: .none,
            conversationReady: true,
            connection: .connected,
            showsTerminal: false
        )
        XCTAssertEqual(model.assistantName, "custom-bot")
    }
}
