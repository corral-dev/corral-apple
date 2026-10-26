import XCTest
@testable import Corral

@MainActor
final class ConversationRetentionTests: XCTestCase {
    private func message(text: String?, toolOutput: String? = nil) -> RichMessage {
        var tools: [ToolCall]?
        if let toolOutput {
            tools = [ToolCall(callID: "t1", name: "Bash", kind: "shell",
                              summary: "run", detail: nil, status: "ok",
                              output: toolOutput)]
        }
        return RichMessage(seq: 1, role: "assistant", text: text, tools: tools)
    }

    func testToolBodiesCountTowardRetainedBytes() {
        let plain = ConversationRetention.estimatedBytes(of: message(text: "hello"))
        let withBody = ConversationRetention.estimatedBytes(
            of: message(text: "hello", toolOutput: String(repeating: "x", count: 120_000))
        )
        XCTAssertGreaterThan(withBody, plain + 110_000)
    }

    func testToolHeavyMessageExceedsWarmPaneBudget() {
        let heavy = message(text: "done", toolOutput: String(repeating: "x", count: 5 * 1024 * 1024))
        XCTAssertGreaterThan(ConversationRetention.estimatedBytes(of: heavy), 4 * 1024 * 1024)
    }

    func testQuestionPromptsAndOptionDetailsCount() {
        let plain = SessionPrompt(id: "q", name: nil, summary: nil, detail: nil, options: [])
        let detailed = SessionPrompt(
            id: "q", name: "Question", summary: String(repeating: "s", count: 10_000),
            detail: String(repeating: "d", count: 10_000), options: ["one", "two"],
            optionDetails: [SessionPromptOption(id: "a", label: "A", description: String(repeating: "x", count: 10_000))]
        )
        XCTAssertGreaterThan(
            ConversationRetention.estimatedBytes(of: detailed),
            ConversationRetention.estimatedBytes(of: plain) + 25_000
        )
    }

    func testEmptyConversationStoreHasNoRetainedPayload() {
        let store = ConversationStore(sessionKey: "session", client: nil, live: false)
        XCTAssertEqual(store.retainedByteEstimate, 0)
    }
}
