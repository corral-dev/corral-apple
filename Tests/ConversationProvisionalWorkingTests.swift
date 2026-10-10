import XCTest
@testable import Corral

/// Working must appear the instant text is submitted, then hand over to the
/// host's authoritative attention.
@MainActor
final class ConversationProvisionalWorkingTests: XCTestCase {
    private func store(attention: AttentionKind = .none) -> ConversationStore {
        ConversationStore(sessionKey: "claude:provisional", client: nil, live: true, attention: attention)
    }

    func testProvisionalShowsWorkingBeforeHostConfirms() {
        let store = store()
        XCTAssertEqual(store.displayAttention, .none)
        store.beginProvisionalWorking()
        XCTAssertEqual(store.displayAttention, .working)
        XCTAssertTrue(store.isAssistantWorking)
        XCTAssertEqual(store.attention, .none, "provisional never rewrites the authoritative value")
    }

    func testAuthoritativeWorkingTakesOver() async {
        let store = store()
        store.beginProvisionalWorking()
        await store.handle(RemoteEvent(channel: "session:claude:provisional", data: [
            "kind": "attention", "session": "claude:provisional", "attention": "working",
        ]))
        XCTAssertNil(store.provisionalWorkingSince)
        XCTAssertEqual(store.displayAttention, .working)
        await store.handle(RemoteEvent(channel: "session:claude:provisional", data: [
            "kind": "attention", "session": "claude:provisional", "attention": "none",
        ]))
        XCTAssertEqual(store.displayAttention, .none)
    }

    func testEarlyIdleSignalDoesNotCancelProvisional() async {
        let store = store()
        store.beginProvisionalWorking()
        await store.handle(RemoteEvent(channel: "session:claude:provisional", data: [
            "kind": "attention", "session": "claude:provisional", "attention": "none",
        ]))
        XCTAssertEqual(store.displayAttention, .working, "an idle event inside the grace predates the send")
    }

    func testLateIdleSignalCancelsProvisional() async {
        let store = store()
        store.beginProvisionalWorking(now: Date().addingTimeInterval(-5))
        await store.handle(RemoteEvent(channel: "session:claude:provisional", data: [
            "kind": "attention", "session": "claude:provisional", "attention": "none",
        ]))
        XCTAssertEqual(store.displayAttention, .none)
    }

    func testHostProvisionalHintStartsCueWithoutAuthority() async {
        let store = store()
        await store.handle(RemoteEvent(channel: "session:claude:provisional", data: [
            "kind": "attention", "session": "claude:provisional", "attention": "working",
            "provisional": true, "live": true,
        ]))
        XCTAssertNotNil(store.provisionalWorkingSince)
        XCTAssertEqual(store.attention, .none)
        XCTAssertEqual(store.displayAttention, .working)
    }

    func testWaitingIsNotMaskedByProvisional() async {
        let store = store(attention: .waiting)
        await store.handle(RemoteEvent(channel: "session:claude:provisional", data: [
            "kind": "attention", "session": "claude:provisional", "attention": "working",
            "provisional": true,
        ]))
        XCTAssertNil(store.provisionalWorkingSince)
        XCTAssertEqual(store.displayAttention, .waiting)
    }

    func testRejectedReceiptCancelsProvisional() {
        let store = store()
        store.beginProvisionalWorking()
        store.applyCommandStatus(commandID: "cmd-1", status: "rejected")
        XCTAssertNil(store.provisionalWorkingSince)
        XCTAssertEqual(store.displayAttention, .none)
    }
}
