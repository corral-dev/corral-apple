import Foundation
@testable import Corral
import XCTest

/// Your prompts covers the whole session, and paging earlier is never undone by the cache budget.
@MainActor
final class SessionUserPromptsTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-prompts-\(UUID().uuidString)", isDirectory: true)
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

    func testOpenConversationKeepsPagesBeyondCacheBudget() async throws {
        let total = ConversationHistoryBudget.maxOfficialMessagesPerSession + 50
        let rows: [[String: Any]] = (1...total).map { ["seq": $0, "role": "assistant", "text": "m\($0)"] }
        let store = ConversationStore(sessionKey: "claude:deep", client: nil, live: false, hostID: "host-a")
        store.applySnapshot(try RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: [
            "messages": rows, "generation": 1, "oldest_seq": 1, "newest_seq": total, "has_more": true,
        ]))
        await store.stop()
        // Only the saved cache is bounded; the open window keeps what was paged in.
        XCTAssertEqual(store.messages.count, total)
        XCTAssertEqual(store.oldestSequence, 1)
        XCTAssertTrue(store.hasMoreHistory)
        let cached = ConversationTailCache.load(hostID: "host-a", sessionKey: "claude:deep")
        XCTAssertEqual(cached?.messages.count, ConversationHistoryBudget.maxOfficialMessagesPerSession)
    }

    func testHostUserPromptsDecodeAndMergeWithLoadedMessages() throws {
        let response = try RemoteJSONDecoder.decode(SessionUserPromptsResponse.self, from: [
            "prompts": [
                ["seq": 3, "role": "user", "text": "first…"],
                ["seq": 900, "role": "user", "text": "loaded…"],
                ["seq": 0, "role": "user", "text": "bad"],
            ],
            "generation": 4,
        ])
        XCTAssertEqual(response.prompts.map(\.seq), [3, 900])
        XCTAssertEqual(response.generation, 4)
        let loaded = try RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: [
            "messages": [
                ["seq": 900, "role": "user", "text": "loaded full text"],
                ["seq": 901, "role": "assistant", "text": "answer"],
            ], "generation": 4, "oldest_seq": 900, "newest_seq": 901,
        ]).messages
        let merged = ConversationMessagePolicy.userPrompts(loaded: loaded, session: response.prompts)
        XCTAssertEqual(merged.map(\.seq), [3, 900])
        XCTAssertEqual(merged.map(\.text), ["first…", "loaded full text"])
    }

    func testHostListIsTheFilterAuthorityUpToItsNewestPrompt() throws {
        let loaded = try RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: [
            "messages": [
                ["seq": 10, "role": "user", "text": "This session is being continued from a previous conversation…"],
                ["seq": 11, "role": "user", "text": "Task: relay\n\nYou are picking up a session from Codex."],
                ["seq": 12, "role": "assistant", "text": "answer"],
                ["seq": 13, "role": "user", "text": "<system-reminder>later injected</system-reminder>"],
                ["seq": 14, "role": "user", "text": "typed after the list"],
            ], "generation": 4, "oldest_seq": 10, "newest_seq": 14,
        ]).messages
        // The host filtered seq 10 and kept the relay prompt it renders natively.
        let host = [RichMessage(seq: 11, role: "user", text: "Task: relay…")]
        let merged = ConversationMessagePolicy.userPrompts(loaded: loaded, session: host)
        XCTAssertEqual(merged.map(\.seq), [11, 14])
    }

    func testHelloDecodesUserPromptsCapability() throws {
        let hello = try RemoteJSONDecoder.decode(HelloResponse.self, from: [
            "paired": true, "capabilities": ["user_prompts": true],
        ])
        XCTAssertTrue(hello.capabilities.userPrompts)
        XCTAssertFalse(HostCapabilities.empty.userPrompts)
    }

    func testDirectPromptCapabilityIsExplicitAndSurvivesHostCacheRoundTrip() throws {
        let old = try JSONDecoder().decode(HostCapabilities.self, from: Data(#"{"terminal_prompt":true}"#.utf8))
        XCTAssertTrue(old.terminalPrompt)
        XCTAssertFalse(old.terminalPromptDirect)
        let direct = try JSONDecoder().decode(HostCapabilities.self,
            from: Data(#"{"terminal_prompt":true,"terminal_prompt_direct":true}"#.utf8))
        XCTAssertTrue(direct.terminalPromptDirect)
        let restored = try JSONDecoder().decode(HostCapabilities.self, from: JSONEncoder().encode(direct))
        XCTAssertTrue(restored.terminalPrompt)
        XCTAssertTrue(restored.terminalPromptDirect)
    }

    func testPromptCacheUpdatesWhenTextOrRoleChangesAtSameSequence() throws {
        let store = ConversationStore(sessionKey: "claude:corrected", client: nil, live: false)
        func apply(_ text: String, role: String = "user") throws {
            store.applySnapshot(try RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: [
                "messages": [["seq": 7, "role": role, "text": text]],
                "generation": 1, "oldest_seq": 7, "newest_seq": 7,
            ]))
        }
        try apply("Original prompt")
        XCTAssertEqual(store.userPrompts.map(\.text), ["Original prompt"])
        try apply("Corrected prompt")
        XCTAssertEqual(store.userPrompts.map(\.text), ["Corrected prompt"])
        try apply("Corrected prompt", role: "assistant")
        XCTAssertTrue(store.userPrompts.isEmpty)
    }
}
