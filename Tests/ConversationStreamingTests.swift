import XCTest
@testable import Corral

@MainActor
final class ConversationStreamingTests: XCTestCase {
    private var cacheTempDir: URL?

    override func tearDown() async throws {
        ConversationTailCache.flushPendingWrites()
        ConversationTailCache.directoryOverride = nil
        if let dir = cacheTempDir {
            try? FileManager.default.removeItem(at: dir)
            cacheTempDir = nil
        }
        try await super.tearDown()
    }

    private func useIsolatedCacheDir() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-stream-tests-\(UUID().uuidString)", isDirectory: true)
        cacheTempDir = dir
        ConversationTailCache.directoryOverride = dir
    }

    private func makeStore(sessionKey: String = "codex:stream-test", hostID: String = "host-stream-test") -> ConversationStore {
        ConversationTailCache.removeAll(hostID: hostID)
        return ConversationStore(sessionKey: sessionKey, client: nil, live: true, hostID: hostID)
    }

    func testWireHelloRequestsChatStreamingAndDecodesCapability() throws {
        let params = WireProtocol.controlHelloParams(name: "Test Device")
        XCTAssertEqual(params[WireProtocol.wantChatStreamingKey] as? Bool, true)
        XCTAssertTrue(WireProtocol.supportsChatStreaming(fromHelloPayload: [
            "capabilities": ["chat_streaming": true]
        ]))

        let data = try JSONSerialization.data(withJSONObject: [
            "paired": true,
            "capabilities": [
                "command_receipts": true,
                "tool_detail": true,
                "chat_streaming": true,
            ],
        ])
        let hello = try JSONDecoder().decode(HelloResponse.self, from: data)
        XCTAssertTrue(hello.capabilities.chatStreaming)

        let legacyData = try JSONSerialization.data(withJSONObject: ["paired": true, "capabilities": [:]])
        let legacyHello = try JSONDecoder().decode(HelloResponse.self, from: legacyData)
        XCTAssertFalse(legacyHello.capabilities.chatStreaming)
    }

    func testRemoteEventDeliveryCoalescesConsecutiveStreamDeltasWithoutResync() async {
        let delivery = RemoteEventDelivery(channel: "session:codex:s1")
        for rev in 1 ... 40 {
            let payload: [String: Any] = [
                "kind": "stream",
                "session": "codex:s1",
                "stream_id": "item_1",
                "op": rev == 1 ? "replace" : "delta",
                "rev": rev,
                "text": rev == 1 ? "H" : NSNull(),
                "delta": rev == 1 ? NSNull() : "x",
                "after_seq": 3,
                "complete": rev == 40,
            ]
            let outcome = delivery.push(RemoteEvent(channel: "session:codex:s1", data: payload), size: 64)
            XCTAssertEqual(outcome, .enqueued)
        }
        XCTAssertFalse(delivery.isGapped)
        XCTAssertEqual(delivery.retentionDepth.events, 1)

        delivery.finish()
        let coalesced = RemoteEventDelivery(channel: "session:codex:s1")
        _ = coalesced.push(RemoteEvent(channel: "session:codex:s1", data: [
            "kind": "stream", "stream_id": "item_1", "op": "replace", "rev": 1, "text": "Hello", "complete": false,
        ]), size: 32)
        _ = coalesced.push(RemoteEvent(channel: "session:codex:s1", data: [
            "kind": "stream", "stream_id": "item_1", "op": "delta", "rev": 2, "delta": " world", "complete": true,
        ]), size: 32)
        let first = await coalesced.next()
        XCTAssertEqual(first?.data["text"] as? String, "Hello world")
        XCTAssertEqual(first?.data["rev"] as? Int, 2)
        XCTAssertEqual(first?.data["complete"] as? Bool, true)

        // Intervening durable messages prevent coalescing across message boundaries.
        let ordered = RemoteEventDelivery(channel: "session:codex:s1")
        _ = ordered.push(RemoteEvent(channel: "session:codex:s1", data: [
            "kind": "stream", "stream_id": "item_1", "op": "delta", "rev": 1, "delta": "a",
        ]), size: 16)
        _ = ordered.push(RemoteEvent(channel: "session:codex:s1", data: [
            "kind": "messages", "messages": [],
        ]), size: 16)
        _ = ordered.push(RemoteEvent(channel: "session:codex:s1", data: [
            "kind": "stream", "stream_id": "item_1", "op": "delta", "rev": 2, "delta": "b",
        ]), size: 16)
        XCTAssertEqual(ordered.retentionDepth.events, 3)
    }

    func testStreamingLifecycleReconcilesAtomicallyWithoutPollutingCacheOrPrompts() async {
        useIsolatedCacheDir()
        let hostID = "host-stream-\(UUID().uuidString)"
        let sessionKey = "codex:conv-1"
        let store = ConversationStore(sessionKey: sessionKey, client: nil, live: true, hostID: hostID)

        let baseline = try! JSONDecoder().decode(
            SessionMessagesResponse.self,
            from: JSONSerialization.data(withJSONObject: [
                "messages": [["seq": 1, "role": "user", "text": "Say hi"]],
                "oldest_seq": 1,
                "newest_seq": 1,
                "has_more": false,
                "generation": 1,
            ])
        )
        store.applySnapshot(baseline)
        XCTAssertEqual(store.newestSequence, 1)

        await store.handle(RemoteEvent(channel: "session:\(sessionKey)", data: [
            "kind": "stream",
            "session": sessionKey,
            "stream_id": "item-1",
            "op": "replace",
            "rev": 1,
            "text": "Hello",
            "after_seq": 1,
            "complete": false,
        ]))
        await store.handle(RemoteEvent(channel: "session:\(sessionKey)", data: [
            "kind": "stream",
            "session": sessionKey,
            "stream_id": "item-1",
            "op": "delta",
            "rev": 2,
            "delta": ", world!",
            "after_seq": 1,
            "complete": true,
        ]))

        XCTAssertEqual(store.streamingDrafts.count, 1)
        XCTAssertEqual(store.streamingDrafts.first?.text, "Hello, world!")
        XCTAssertEqual(store.newestSequence, 1)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.userPrompts.count, 1)
        guard case .message(let draftMsg)? = store.timelineItems.last else {
            return XCTFail("Expected streaming message in timeline")
        }
        XCTAssertTrue(draftMsg.isStreaming)
        XCTAssertFalse(draftMsg.isLocal)
        XCTAssertEqual(draftMsg.text, "Hello, world!")
        XCTAssertLessThanOrEqual(draftMsg.seq, -1_000_000)

        // Tail cache must never retain ephemeral streaming drafts.
        ConversationTailCache.flushPendingWrites()
        XCTAssertNil(ConversationTailCache.load(hostID: hostID, sessionKey: sessionKey))

        // Atomic handoff when official seq 2 arrives.
        await store.handle(RemoteEvent(channel: "session:\(sessionKey)", data: [
            "messages": [[
                "seq": 2,
                "role": "assistant",
                "text": "Hello, world!",
                "ts": 1234.0,
            ]],
            "from_seq": 2,
        ]))

        XCTAssertTrue(store.streamingDrafts.isEmpty)
        XCTAssertEqual(store.newestSequence, 2)
        XCTAssertEqual(store.timelineItems.count, 2)
        guard case .message(let officialMsg)? = store.timelineItems.last else {
            return XCTFail("Expected official message in timeline")
        }
        XCTAssertEqual(officialMsg.seq, 2)
        XCTAssertFalse(officialMsg.isStreaming)

        ConversationTailCache.flushPendingWrites()
        let cached = ConversationTailCache.load(hostID: hostID, sessionKey: sessionKey)
        XCTAssertEqual(cached?.messages.map(\.seq), [1, 2])
    }

    func testMidTurnSnapshotRestoresActiveStreamsAndResetClearsThem() async {
        useIsolatedCacheDir()
        let store = makeStore()
        let data = try! JSONSerialization.data(withJSONObject: [
            "messages": [["seq": 1, "role": "user", "text": "Hi"]],
            "oldest_seq": 1,
            "newest_seq": 1,
            "has_more": false,
            "generation": 2,
            "active_streams": [[
                "stream_id": "item-live",
                "rev": 3,
                "text": "Partial answer",
                "after_seq": 1,
                "complete": false,
            ]],
        ])
        let snapshot = try! JSONDecoder().decode(SessionMessagesResponse.self, from: data)
        store.applySnapshot(snapshot)

        XCTAssertEqual(store.streamingDrafts.count, 1)
        XCTAssertEqual(store.streamingDrafts.first?.text, "Partial answer")

        await store.handle(RemoteEvent(channel: "session:codex:stream-test", data: [
            "kind": "history_reset",
            "session": "codex:stream-test",
            "messages": [],
            "oldest_seq": 0,
            "newest_seq": 0,
            "has_more": false,
            "generation": 3,
        ]))
        XCTAssertTrue(store.streamingDrafts.isEmpty)
    }
}
