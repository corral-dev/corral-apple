import Foundation
@testable import Corral
import XCTest

@MainActor
final class ConversationTailCacheTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tails-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ConversationTailCache.directoryOverride = scratch
        PendingCommandStore.directoryOverride = scratch.appendingPathComponent("pending", isDirectory: true)
    }

    override func tearDown() async throws {
        ConversationTailCache.flushPendingWrites()
        ConversationTailCache.directoryOverride = nil
        PendingCommandStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testSaveLoadRoundTrip() {
        let snapshot = ConversationTailSnapshot(
            hostID: "host-a",
            sessionKey: "claude:abc",
            messages: [
                RichMessage(seq: 1, role: "user", text: "你好", delivery: .sent),
                RichMessage(seq: 2, role: "assistant", text: "在", delivery: .sent),
            ],
            oldestSequence: 1,
            newestSequence: 2,
            hasMoreHistory: true,
            generation: 3,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        ConversationTailCache.save(snapshot)

        let loaded = ConversationTailCache.load(hostID: "host-a", sessionKey: "claude:abc")
        XCTAssertEqual(loaded?.messages.map(\.text), ["你好", "在"])
        XCTAssertEqual(loaded?.newestSequence, 2)
        XCTAssertEqual(loaded?.generation, 3)
        XCTAssertTrue(loaded?.hasMoreHistory == true)
    }

    func testDifferentHostDoesNotReuseTail() {
        ConversationTailCache.save(
            ConversationTailSnapshot(
                hostID: "host-a",
                sessionKey: "codex:1",
                messages: [RichMessage(seq: 1, role: "user", text: "A机", delivery: .sent)],
                oldestSequence: 1,
                newestSequence: 1,
                hasMoreHistory: false,
                generation: 1,
                savedAt: Date()
            )
        )
        XCTAssertNil(ConversationTailCache.load(hostID: "host-b", sessionKey: "codex:1"))
    }

    func testRemoveHostClearsTails() {
        ConversationTailCache.save(
            ConversationTailSnapshot(
                hostID: "host-a",
                sessionKey: "pi:1",
                messages: [RichMessage(seq: 1, role: "assistant", text: "留着", delivery: .sent)],
                oldestSequence: 1,
                newestSequence: 1,
                hasMoreHistory: false,
                generation: 0,
                savedAt: Date()
            )
        )
        ConversationTailCache.removeAll(hostID: "host-a")
        XCTAssertNil(ConversationTailCache.load(hostID: "host-a", sessionKey: "pi:1"))
    }

    func testPendingWriteIsVisibleAndReachesDiskAfterFlush() throws {
        let snapshot = ConversationTailSnapshot(
            hostID: "host-a",
            sessionKey: "codex:pending",
            messages: [RichMessage(seq: 1, role: "user", text: "first", delivery: .sent)],
            oldestSequence: 1,
            newestSequence: 1,
            hasMoreHistory: false,
            generation: 1,
            savedAt: Date()
        )
        ConversationTailCache.save(snapshot)
        var newer = snapshot
        newer.messages.append(RichMessage(seq: 2, role: "assistant", text: "second", delivery: .sent))
        newer.newestSequence = 2
        ConversationTailCache.save(newer)

        // The newest pending snapshot wins before anything reaches disk.
        XCTAssertEqual(ConversationTailCache.load(hostID: "host-a", sessionKey: "codex:pending")?.newestSequence, 2)

        ConversationTailCache.flushPendingWrites()
        let url = try XCTUnwrap(ConversationTailCache.fileURL(hostID: "host-a", sessionKey: "codex:pending"))
        let onDisk = try JSONDecoder().decode(ConversationTailSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.messages.map(\.text), ["first", "second"])
    }

    func testRemoveAllCancelsPendingWrites() throws {
        ConversationTailCache.save(
            ConversationTailSnapshot(
                hostID: "host-gone",
                sessionKey: "claude:1",
                messages: [RichMessage(seq: 1, role: "user", text: "secret", delivery: .sent)],
                oldestSequence: 1,
                newestSequence: 1,
                hasMoreHistory: false,
                generation: 1,
                savedAt: Date()
            )
        )
        ConversationTailCache.removeAll(hostID: "host-gone")
        XCTAssertNil(ConversationTailCache.load(hostID: "host-gone", sessionKey: "claude:1"))

        ConversationTailCache.flushPendingWrites()
        let url = try XCTUnwrap(ConversationTailCache.fileURL(hostID: "host-gone", sessionKey: "claude:1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLRUEvictsWhenOverSessionCap() {
        for index in 0..<ConversationTailCache.maxSessions + 3 {
            ConversationTailCache.save(
                ConversationTailSnapshot(
                    hostID: "host-a",
                    sessionKey: "sess:\(index)",
                    messages: [RichMessage(seq: 1, role: "user", text: "m\(index)", delivery: .sent)],
                    oldestSequence: 1,
                    newestSequence: 1,
                    hasMoreHistory: false,
                    generation: 0,
                    savedAt: Date()
                )
            )
        }
        ConversationTailCache.flushPendingWrites()
        // Oldest should be gone; most recent retained.
        XCTAssertNil(ConversationTailCache.load(hostID: "host-a", sessionKey: "sess:0"))
        XCTAssertNotNil(
            ConversationTailCache.load(
                hostID: "host-a",
                sessionKey: "sess:\(ConversationTailCache.maxSessions + 2)"
            )
        )
    }

    func testPendingCommandStatusMapping() {
        XCTAssertEqual(PendingCommandStore.delivery(fromHostStatus: "accepted"), .accepted)
        XCTAssertEqual(PendingCommandStore.delivery(fromHostStatus: "dispatching"), .accepted)
        XCTAssertEqual(PendingCommandStore.delivery(fromHostStatus: "delivered"), .sent)
        XCTAssertEqual(PendingCommandStore.delivery(fromHostStatus: "rejected"), .failed)
        XCTAssertEqual(PendingCommandStore.delivery(fromHostStatus: "unknown"), .needsReview)
        XCTAssertEqual(PendingCommandStore.delivery(fromHostStatus: "unseen"), .pending)
    }

    func testPendingCommandPersistAndClearOnHostRemoval() {
        PendingCommandStore.upsert(
            PendingCommandRecord(
                commandID: "cmd-1",
                hostID: "host-a",
                sessionKey: "claude:x",
                text: "在吗",
                localSeq: -1,
                delivery: .pending,
                createdAt: Date()
            )
        )
        XCTAssertEqual(PendingCommandStore.unresolved(hostID: "host-a", sessionKey: "claude:x").count, 1)
        PendingCommandStore.updateDelivery(hostID: "host-a", commandID: "cmd-1", delivery: .needsReview)
        XCTAssertEqual(
            PendingCommandStore.unresolved(hostID: "host-a", sessionKey: "claude:x").first?.delivery,
            .needsReview
        )
        PendingCommandStore.removeAll(hostID: "host-a")
        XCTAssertTrue(PendingCommandStore.load(hostID: "host-a").isEmpty)
    }

    func testCommandReceiptCapabilityParsing() {
        XCTAssertFalse(WireProtocol.supportsCommandReceipts(fromHelloPayload: ["paired": true]))
        XCTAssertTrue(
            WireProtocol.supportsCommandReceipts(fromHelloPayload: [
                "capabilities": ["command_receipts": true, "planes": ["control", "data"]],
            ])
        )
        XCTAssertTrue(
            WireProtocol.supportsCommandReceipts(fromHelloPayload: [
                "capabilities": ["features": ["command_receipts"]],
            ])
        )
        XCTAssertFalse(
            WireProtocol.supportsCommandReceipts(fromHelloPayload: [
                "capabilities": ["planes": ["control", "data"]],
            ])
        )
    }

    func testHelloResponseDecodesCapabilities() throws {
        let hello = try RemoteJSONDecoder.decode(
            HelloResponse.self,
            from: [
                "paired": true,
                "capabilities": [
                    "command_receipts": true,
                    "planes": ["control", "data"],
                ],
            ]
        )
        XCTAssertTrue(hello.capabilities.commandReceipts)
        XCTAssertFalse(hello.capabilities.toolDetail)
    }

    func testToolDetailCapabilityParsing() {
        XCTAssertTrue(
            WireProtocol.supportsToolDetail(fromHelloPayload: [
                "capabilities": ["tool_detail": true],
            ])
        )
        XCTAssertFalse(
            WireProtocol.supportsToolDetail(fromHelloPayload: [
                "capabilities": ["command_receipts": true],
            ])
        )
    }

    func testRichMessagePersistsLocalDeliveryAndCommandID() throws {
        let message = RichMessage(
            seq: -1,
            role: "user",
            text: "pending",
            delivery: .pending,
            commandID: "abc"
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(RichMessage.self, from: data)
        XCTAssertEqual(decoded.delivery, .pending)
        XCTAssertEqual(decoded.commandID, "abc")
    }
}

@MainActor
final class ConversationCommandReconcileTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-cmd-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ConversationTailCache.directoryOverride = scratch
        PendingCommandStore.directoryOverride = scratch.appendingPathComponent("pending", isDirectory: true)
    }

    override func tearDown() async throws {
        ConversationTailCache.flushPendingWrites()
        ConversationTailCache.directoryOverride = nil
        PendingCommandStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testStorePaintsCachedTailBeforeNetwork() {
        ConversationTailCache.save(
            ConversationTailSnapshot(
                hostID: "host-a",
                sessionKey: "claude:cached",
                messages: [
                    RichMessage(seq: 10, role: "user", text: "缓存的提问", delivery: .sent),
                    RichMessage(seq: 11, role: "assistant", text: "缓存的回答", delivery: .sent),
                ],
                oldestSequence: 10,
                newestSequence: 11,
                hasMoreHistory: false,
                generation: 2,
                savedAt: Date()
            )
        )
        let store = ConversationStore(
            sessionKey: "claude:cached",
            client: nil,
            live: false,
            hostID: "host-a"
        )
        XCTAssertEqual(store.messages.map(\.text), ["缓存的提问", "缓存的回答"])
        XCTAssertEqual(store.newestSequence, 11)
        XCTAssertFalse(store.isLoading)
    }

    private func forkSource() -> ConversationStore {
        ConversationTailCache.save(ConversationTailSnapshot(
            hostID: "host-a", sessionKey: "claude:source",
            messages: [
                RichMessage(seq: 40, role: "user", text: "Original question", delivery: .sent),
                RichMessage(seq: 41, role: "assistant", text: "Original answer", delivery: .sent),
                RichMessage(seq: -1, role: "user", text: "Unresolved send", delivery: .pending),
            ],
            oldestSequence: 40, newestSequence: 41, hasMoreHistory: true,
            generation: 9, savedAt: Date()
        ))
        return ConversationStore(sessionKey: "claude:source", client: nil, live: true,
                                 attention: .waiting, hostID: "host-a")
    }

    func testForkPaintsInheritedHistoryWithIndependentIdentityBeforeNetwork() {
        let source = forkSource()
        let original = source.messages
        source.seedFork(sessionKey: "claude:fork")
        let fork = ConversationStore(sessionKey: "claude:fork", client: nil, live: false, hostID: "host-a")
        XCTAssertEqual(fork.visibleMessages.map(\.text), ["Original question", "Original answer"])
        XCTAssertEqual(fork.timelineItems.count, 2)
        XCTAssertTrue(fork.messages.isEmpty)
        XCTAssertEqual(fork.newestSequence, 0)
        XCTAssertEqual(fork.oldestSequence, 0)
        XCTAssertFalse(fork.hasMoreHistory)
        XCTAssertFalse(fork.isLoading)
        XCTAssertTrue(fork.prompts.isEmpty)
        XCTAssertEqual(fork.attention, .none)
        XCTAssertEqual(source.messages, original)
        let otherHost = ConversationStore(sessionKey: "claude:fork", client: nil, live: false, hostID: "host-b")
        XCTAssertTrue(otherHost.visibleMessages.isEmpty)
    }

    func testForkRetainsHistoryThroughEmptySnapshotAndReopenThenReconciles() async throws {
        forkSource().seedFork(sessionKey: "claude:fork")
        let fork = ConversationStore(sessionKey: "claude:fork", client: nil, live: false, hostID: "host-a")
        let empty = try RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: [
            "messages": [], "generation": 1, "resume": "tail"
        ])
        fork.applySnapshot(empty)
        XCTAssertEqual(fork.visibleMessages.count, 2)
        await fork.stop()
        let reopened = ConversationStore(sessionKey: "claude:fork", client: nil, live: false, hostID: "host-a")
        XCTAssertEqual(reopened.visibleMessages.map(\.text), ["Original question", "Original answer"])
        let localSeq = reopened.enqueueLocalUser("New fork question", commandID: "fork-command")
        let tail = try RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: [
            "messages": [
                ["seq": 1, "role": "user", "text": "Original question"],
                ["seq": 2, "role": "assistant", "text": "Original answer"]
            ], "generation": 2, "oldest_seq": 1, "newest_seq": 2
        ])
        reopened.applySnapshot(tail)
        XCTAssertEqual(reopened.visibleMessages.filter { $0.seq > 0 }.map(\.seq), [1, 2])
        XCTAssertEqual(reopened.visibleMessages.filter { $0.seq > 0 }.map(\.text),
                       ["Original question", "Original answer"])
        XCTAssertTrue(reopened.messages.contains { $0.seq == localSeq && $0.commandID == "fork-command" })
        await reopened.stop()
        XCTAssertNil(ConversationTailCache.load(hostID: "host-a", sessionKey: "claude:fork")?.forkMessages)
    }

    func testEarlyForkDeltaDoesNotReplaceInheritedMessagesBySourceSequence() async throws {
        forkSource().seedFork(sessionKey: "claude:fork")
        let fork = ConversationStore(sessionKey: "claude:fork", client: nil, live: false, hostID: "host-a")
        await fork.handle(RemoteEvent(channel: "session:claude:fork", data: [
            "kind": "delta", "messages": [["seq": 40, "role": "assistant", "text": "Destination update"]]
        ]))
        XCTAssertEqual(fork.visibleMessages.map(\.text), ["Original question", "Original answer"])
        XCTAssertEqual(fork.messages.map(\.text), ["Destination update"])
        let details = await fork.fetchToolDetails(messageSeq: 40)
        XCTAssertNil(details)
    }

    func testHistoryBudgetKeepsEarlierPagesUnderCap() {
        var messages: [RichMessage] = []
        for seq in 1...120 {
            messages.append(RichMessage(seq: seq, role: "user", text: "m\(seq)", delivery: .sent))
        }
        let snapshot = ConversationHistoryBudget.snapshot(
            hostID: "host-a",
            sessionKey: "claude:long",
            messages: messages,
            hasMoreHistory: true,
            generation: 2
        )
        XCTAssertEqual(snapshot.messages.count, 120)
        XCTAssertEqual(snapshot.oldestSequence, 1)
        XCTAssertEqual(snapshot.newestSequence, 120)
        XCTAssertTrue(snapshot.hasMoreHistory)
        ConversationTailCache.save(snapshot)
        let loaded = ConversationTailCache.load(hostID: "host-a", sessionKey: "claude:long")
        XCTAssertEqual(loaded?.messages.count, 120)
        XCTAssertEqual(loaded?.oldestSequence, 1)
    }

    func testHistoryBudgetTrimsOldestAndRecomputesCursors() {
        var messages: [RichMessage] = []
        let total = ConversationHistoryBudget.maxOfficialMessagesPerSession + 50
        for seq in 1...total {
            messages.append(RichMessage(seq: seq, role: "assistant", text: "m\(seq)", delivery: .sent))
        }
        let snapshot = ConversationHistoryBudget.snapshot(
            hostID: "host-a",
            sessionKey: "claude:huge",
            messages: messages,
            hasMoreHistory: false,
            generation: 1
        )
        XCTAssertEqual(snapshot.messages.count, ConversationHistoryBudget.maxOfficialMessagesPerSession)
        XCTAssertEqual(
            snapshot.oldestSequence,
            total - ConversationHistoryBudget.maxOfficialMessagesPerSession + 1
        )
        XCTAssertEqual(snapshot.newestSequence, total)
        XCTAssertTrue(snapshot.hasMoreHistory, "trimming must revive has_more")
    }

    func testStorePersistKeepsLoadedEarlierPagesAcrossReopen() {
        // Simulate watch tail + two earlier pages already merged in memory.
        var messages: [RichMessage] = []
        for seq in 41...200 {
            messages.append(RichMessage(seq: seq, role: "user", text: "m\(seq)", delivery: .sent))
        }
        // Drive through cache as stop() would after loadEarlier.
        let snapshot = ConversationHistoryBudget.snapshot(
            hostID: "host-a",
            sessionKey: "claude:pages",
            messages: messages,
            hasMoreHistory: true,
            generation: 7
        )
        ConversationTailCache.save(snapshot)

        let reopened = ConversationStore(
            sessionKey: "claude:pages",
            client: nil,
            live: false,
            hostID: "host-a"
        )
        XCTAssertEqual(reopened.messages.count, 160)
        XCTAssertEqual(reopened.oldestSequence, 41)
        XCTAssertEqual(reopened.newestSequence, 200)
        XCTAssertTrue(reopened.hasMoreHistory)
        XCTAssertGreaterThan(reopened.messages.count, WireProtocol.messagePageLimit)
    }

    func testApplyUnknownStatusMarksNeedsReviewWithoutResend() {
        let store = ConversationStore(
            sessionKey: "claude:x",
            client: nil,
            live: true,
            hostID: "host-a"
        )
        let commandID = "cmd-unknown"
        let seq = store.enqueueLocalUser("可能丢了", commandID: commandID)
        store.recordPendingCommand(commandID: commandID, text: "可能丢了", localSeq: seq)
        store.applyCommandStatus(commandID: commandID, status: "unknown")
        XCTAssertEqual(store.messages.first?.delivery, .needsReview)
        XCTAssertEqual(
            PendingCommandStore.unresolved(hostID: "host-a", sessionKey: "claude:x").first?.delivery,
            .needsReview
        )
    }

    func testAcceptedThenDeliveredProgression() {
        let store = ConversationStore(
            sessionKey: "claude:x",
            client: nil,
            live: true,
            hostID: "host-a"
        )
        let commandID = UUID().uuidString
        let seq = store.enqueueLocalUser("进展", commandID: commandID)
        store.recordPendingCommand(commandID: commandID, text: "进展", localSeq: seq)
        store.applyCommandStatus(commandID: commandID, status: "accepted")
        XCTAssertEqual(store.messages.first?.delivery, .accepted)
        store.applyCommandStatus(commandID: commandID, status: "delivered")
        XCTAssertEqual(store.messages.first?.delivery, .sent)
        XCTAssertTrue(PendingCommandStore.unresolved(hostID: "host-a", sessionKey: "claude:x").isEmpty)
    }
}
