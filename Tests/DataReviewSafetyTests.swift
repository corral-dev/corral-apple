import Foundation
@testable import Corral
import XCTest

/// Data-review safety regressions: identity, async-result lifetime and generation.
///
/// Scope: Store/Models/Protocol + ConversationStore/Timeline. Portable: this file
/// is included in the portable manifest (AppModel runtime tests live in
/// AppModelIdentityTests.swift, which is Xcode-only).
/// Network/Push/UI files are owned by other continuations; this file must not
/// import or drive them.
@MainActor
final class DataReviewSafetyTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-data-review-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        SessionListCache.directoryOverride = scratch
        ConversationTailCache.directoryOverride = scratch.appendingPathComponent("tails", isDirectory: true)
        PendingCommandStore.directoryOverride = scratch.appendingPathComponent("pending", isDirectory: true)
    }

    override func tearDown() async throws {
        SessionListCache.flushPendingWrites()
        ConversationTailCache.flushPendingWrites()
        SessionListCache.directoryOverride = nil
        ConversationTailCache.directoryOverride = nil
        PendingCommandStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    // MARK: - List cache host isolation on store reuse

    func testStoreReuseSwitchingToUncachedHostClearsForeignData() throws {
        let store = SessionListStore()
        store.loadPersisted(hostID: "host-a")
        store.applyListResponse(
            SessionsListResponse(
                sessions: [try session(key: "claude:a", title: "A机")],
                version: "v-a"
            )
        )
        XCTAssertEqual(store.sections.flatMap(\.sessions).map(\.key), ["claude:a"])

        // Same instance, new host with no cache: must not show or persist A's rows.
        store.loadPersisted(hostID: "host-b")
        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertEqual(store.version, "")
        XCTAssertNil(store.session(for: "claude:a"))
    }

    // MARK: - Local identity: command_id, not text

    func testSameTextDistinctCommandIDsStayDistinct() {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
        let first = store.enqueueLocalUser("在吗", commandID: "cmd-1")
        let second = store.enqueueLocalUser("在吗", commandID: "cmd-2")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.messages.count, 2)

        // Same command identity reuses its bubble.
        let reused = store.enqueueLocalUser("在吗", commandID: "cmd-1")
        XCTAssertEqual(reused, first)
        XCTAssertEqual(store.messages.count, 2)
    }

    // MARK: - Generation supersedes even replay

    func testGenerationMismatchSupersedesEvenReplay() throws {
        let old = try message(seq: 50, role: "assistant", text: "旧代")
        var pending = RichMessage(seq: -1, role: "user", text: "在路上", delivery: .pending)
        pending.localAfterSeq = 50
        let incoming = try [message(seq: 1, role: "assistant", text: "新代")]
        let applied = ConversationWatchApply.apply(
            local: [old, pending],
            localOldest: 50,
            localNewest: 50,
            localHasMore: false,
            localGeneration: 3,
            incoming: incoming,
            incomingOldest: 1,
            incomingNewest: 1,
            incomingHasMore: false,
            incomingGeneration: 4,
            resume: "replay"
        )
        XCTAssertFalse(applied.messages.contains(where: { $0.seq == 50 }))
        XCTAssertTrue(applied.messages.contains(where: { $0.seq == -1 }))
        XCTAssertTrue(applied.messages.contains(where: { $0.seq == 1 }))
        XCTAssertEqual(applied.generation, 4)
    }

    // MARK: - Stopped view rejects late results

    func testHandleAfterStopDropsLateEvents() async throws {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "delta",
            "session": "k",
            "messages": [["seq": 10, "role": "assistant", "text": "先到"]],
        ]))
        XCTAssertEqual(store.messages.map(\.seq), [10])
        await store.stop()
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "delta",
            "session": "k",
            "messages": [["seq": 11, "role": "assistant", "text": "迟到"]],
        ]))
        XCTAssertEqual(store.messages.map(\.seq), [10])
    }

    func testSubmitUnknownQuestionMarksStale() async {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
        await store.submitQuestion(requestID: "nope", answers: [])
        XCTAssertEqual(store.questionSubmissionState?.requestID, "nope")
        guard case .stale = store.questionSubmissionState?.status else {
            return XCTFail("unknown question must be marked stale")
        }
    }

    func testStopClearsLoadingFlags() async {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
#if DEBUG
        store.setLoadingForLayoutTest(true)
        XCTAssertTrue(store.isLoading)
#endif
        await store.stop()
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isLoadingHistory)
    }

    // MARK: - Deferred tool-detail lifetime (suspended response)

#if DEBUG
    func testStoppedToolDetailRequestDoesNotClobber() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 7, count: 32))
        let store = ConversationStore(sessionKey: "k", client: client, live: true)
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "delta",
            "session": "k",
            "messages": [[
                "seq": 5,
                "role": "assistant",
                "text": "work",
                "tools": [[
                    "id": "t1", "name": "read", "kind": "other",
                    "summary": "read", "status": "completed", "has_detail": true,
                ]],
            ]],
        ]))
        XCTAssertTrue(store.messages.first?.tools?.first?.needsDetailFetch ?? false)

        let gate = AsyncGate()
        let entered = AsyncGate()
        store.toolDetailRequestForTesting = { seq in
            XCTAssertEqual(seq, 5)
            await entered.open()
            await gate.wait()
            return try RemoteJSONDecoder.decode(
                SessionToolDetailResponse.self,
                from: [
                    "seq": 5,
                    "tools": [[
                        "id": "t1", "name": "read", "kind": "other",
                        "summary": "read", "status": "completed",
                        "detail": "late body", "has_detail": true,
                    ]],
                    "offset": 0, "has_more": false, "total": 1,
                ]
            )
        }
        let task = Task { @MainActor in await store.fetchToolDetails(messageSeq: 5) }
        await entered.wait()
        await store.stop()
        await gate.open()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(store.messages.first?.tools?.first?.needsDetailFetch ?? false)
    }

    func testMismatchedToolDetailSeqDoesNotClobber() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 7, count: 32))
        let store = ConversationStore(sessionKey: "k", client: client, live: true)
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "delta",
            "session": "k",
            "messages": [[
                "seq": 5,
                "role": "assistant",
                "text": "work",
                "tools": [[
                    "id": "t1", "name": "read", "kind": "other",
                    "summary": "read", "status": "completed", "has_detail": true,
                ]],
            ]],
        ]))
        store.toolDetailRequestForTesting = { _ in
            try RemoteJSONDecoder.decode(
                SessionToolDetailResponse.self,
                from: [
                    "seq": 999,
                    "tools": [[
                        "id": "t1", "name": "read", "kind": "other",
                        "summary": "read", "status": "completed",
                        "detail": "wrong seq", "has_detail": true,
                    ]],
                    "offset": 0, "has_more": false, "total": 1,
                ]
            )
        }
        let result = await store.fetchToolDetails(messageSeq: 5)
        XCTAssertNil(result)
        XCTAssertTrue(store.messages.first?.tools?.first?.needsDetailFetch ?? false)
    }
#endif

    // MARK: - Helpers

    private func session(key: String, title: String) throws -> SessionSummary {
        try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": key,
            "title": title,
            "cwd": "/tmp/p",
            "cwd_display": "/tmp/p",
            "mtime": 1_700_000_000,
            "time": "12:00",
            "size_kb": 1,
            "status": "ended",
            "live": false,
            "hosted": false,
            "attention": "none",
            "last_user": "问",
            "last_agent": "答",
            "rich": false,
            "pinned": false,
        ])
    }

    private func message(seq: Int, role: String, text: String) throws -> RichMessage {
        try RemoteJSONDecoder.decode(RichMessage.self, from: ["seq": seq, "role": role, "text": text])
    }
}

/// One-shot gate: `open()` before `wait()` still lets the waiter through,
/// so the suspended-response tests stay deterministic either way.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
