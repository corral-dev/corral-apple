import Foundation
import XCTest
@testable import Corral

@MainActor
final class ConversationPresentationTests: XCTestCase {
    private func client() -> RemoteClient {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        _ = client.installPlaneForTesting(isControl: true)
        client.controlConfirmed = true
        return client
    }

    private func request(_ method: String, on client: RemoteClient) async throws -> Int {
        for _ in 0..<2_000 {
            if let id = client.pendingRequests.first(where: { $0.value.method == method })?.key {
                return id
            }
            await Task.yield()
        }
        return try XCTUnwrap(client.pendingRequests.first(where: { $0.value.method == method })?.key,
                             "Missing request: \(method)")
    }

    private func reply(_ id: Int, on client: RemoteClient, data: [String: Any]) {
        client.dispatch(["t": "res", "id": id, "ok": true, "d": data])
    }

    private func finishSnapshot(on client: RemoteClient, text: String) async throws {
        let watch = try await request(WireProtocol.mSessionWatch, on: client)
        reply(watch, on: client, data: [
            "messages": [
                ["seq": 1, "role": "user", "text": "Question"],
                ["seq": 2, "role": "assistant", "text": text],
            ],
            "generation": 1, "oldest_seq": 1, "newest_seq": 2,
            "has_more": false, "resume": "tail",
        ])
        let prompts = try await request(WireProtocol.mSessionPrompts, on: client)
        reply(prompts, on: client, data: ["prompts": []])
    }

    private func present(_ owner: ConversationPresentation, client: RemoteClient, key: String = "pi:test") -> ConversationStore {
        owner.present(sessionKey: key, hostID: "", client: client, live: true, attention: .none)
    }

    private func waitForLoaded(_ store: ConversationStore) async {
        for _ in 0..<2_000 where store.isLoading { await Task.yield() }
        XCTAssertFalse(store.isLoading)
    }

    func testRenderingTaskCancellationKeepsInitialSnapshotAndAssistantEvents() async throws {
        let client = client(), owner = ConversationPresentation()
        defer { owner.dismiss(); client.disconnect() }
        let render = Task {
            _ = present(owner, client: client)
            while !Task.isCancelled { await Task.yield() }
        }
        _ = try await request(WireProtocol.mSessionWatch, on: client)
        render.cancel()
        await render.value
        let store = try XCTUnwrap(owner.store)
        XCTAssertTrue(store.isLoading)
        try await finishSnapshot(on: client, text: "Initial assistant reply")
        await waitForLoaded(store)
        XCTAssertEqual(store.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(store.messages.last?.text, "Initial assistant reply")

        client.dispatch(["t": "evt", "c": "session:pi:test", "d": [
            "messages": [["seq": 3, "role": "assistant", "text": "Live assistant reply"]],
        ]])
        for _ in 0..<2_000 where store.messages.count < 3 { await Task.yield() }
        XCTAssertEqual(store.messages.last?.text, "Live assistant reply")
        XCTAssertEqual(store.timelineItems.count, 3)
    }

    func testSameSelectionReusesStoreAndDoesNotRestartWatch() async throws {
        let client = client(), owner = ConversationPresentation()
        defer { owner.dismiss(); client.disconnect() }
        let first = present(owner, client: client, key: "claude:test")
        try await finishSnapshot(on: client, text: "Claude reply")
        await waitForLoaded(first)
        let requestID = client.nextRequestID
        let again = present(owner, client: client, key: "claude:test")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(first === again)
        XCTAssertEqual(client.nextRequestID, requestID)
        XCTAssertEqual(again.messages.last?.text, "Claude reply")
    }

    func testReturningToSameKeyWaitsForOldUnwatch() async throws {
        let client = client(), owner = ConversationPresentation()
        defer { owner.dismiss(); client.disconnect() }
        let old = present(owner, client: client)
        let oldWatch = try await request(WireProtocol.mSessionWatch, on: client)
        owner.dismiss()
        let replacement = present(owner, client: client)
        XCTAssertFalse(old === replacement)
        let unwatch = try await request(WireProtocol.mSessionUnwatch, on: client)
        XCTAssertFalse(client.pendingRequests.values.contains { $0.method == WireProtocol.mSessionWatch })
        // A delayed response from the old detail must never populate its replacement.
        reply(oldWatch, on: client, data: ["messages": [["seq": 1, "role": "assistant", "text": "Stale"]]])
        XCTAssertTrue(replacement.messages.isEmpty)
        reply(unwatch, on: client, data: [:])
        try await finishSnapshot(on: client, text: "Replacement reply")
        await waitForLoaded(replacement)
        XCTAssertEqual(replacement.messages.last?.text, "Replacement reply")
        XCTAssertEqual(old.messages.count, 0)
    }

    func testClientReplacementRebindsSameSelectedSession() async throws {
        let oldClient = client(), newClient = client(), owner = ConversationPresentation()
        defer { owner.dismiss(); oldClient.disconnect(); newClient.disconnect() }
        let first = present(owner, client: oldClient)
        try await finishSnapshot(on: oldClient, text: "Before reconnect")
        await waitForLoaded(first)
        let replacement = present(owner, client: newClient)
        XCTAssertFalse(first === replacement)
        XCTAssertTrue(replacement.boundClient === newClient)
        let unwatch = try await request(WireProtocol.mSessionUnwatch, on: oldClient)
        XCTAssertTrue(newClient.pendingRequests.isEmpty)
        reply(unwatch, on: oldClient, data: [:])
        try await finishSnapshot(on: newClient, text: "After reconnect")
        await waitForLoaded(replacement)
        XCTAssertEqual(replacement.messages.last?.text, "After reconnect")
    }

    func testDifferentSessionCannotReceivePreviousSessionsHistory() async throws {
        let client = client(), owner = ConversationPresentation()
        defer { owner.dismiss(); client.disconnect() }
        let first = present(owner, client: client, key: "claude:first")
        try await finishSnapshot(on: client, text: "First reply")
        await waitForLoaded(first)
        let second = present(owner, client: client, key: "pi:second")
        let unwatch = try await request(WireProtocol.mSessionUnwatch, on: client)
        XCTAssertTrue(second.messages.isEmpty)
        reply(unwatch, on: client, data: [:])
        try await finishSnapshot(on: client, text: "Second reply")
        await waitForLoaded(second)
        XCTAssertEqual(first.messages.last?.text, "First reply")
        XCTAssertEqual(second.messages.last?.text, "Second reply")
        owner.dismiss()
        let finalUnwatch = try await request(WireProtocol.mSessionUnwatch, on: client)
        reply(finalUnwatch, on: client, data: [:])
        XCTAssertNil(owner.store)
        for _ in 0..<2_000 where client.diagnosticState.subscriptions > 0 { await Task.yield() }
        XCTAssertEqual(client.diagnosticState.subscriptions, 0)
    }
}
