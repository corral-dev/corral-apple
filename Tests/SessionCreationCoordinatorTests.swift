import Foundation
@testable import Corral
import XCTest

@MainActor
final class SessionCreationCoordinatorTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        PendingSessionCreationStore.directoryOverride = scratch
        PendingCommandStore.directoryOverride = scratch
        ConversationTailCache.directoryOverride = scratch
    }

    override func tearDown() async throws {
        PendingSessionCreationStore.directoryOverride = nil
        PendingCommandStore.directoryOverride = nil
        ConversationTailCache.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    func testLostReplyReusesIdentityAndRecoversResult() async throws {
        var ids: [String] = []
        do {
            _ = try await SessionCreationCoordinator.create(
                hostID: "host", runtimeID: "codex", cwd: "/fixture", supportsReceipts: true
            ) { _, params in
                ids.append(params["command_id"] as! String)
                throw URLError(.timedOut)
            }
            XCTFail("Lost reply must remain unresolved")
        } catch is URLError {}
        let session = try await SessionCreationCoordinator.create(
            hostID: "host", runtimeID: "codex", cwd: "/fixture", supportsReceipts: true
        ) { _, params in
            ids.append(params["command_id"] as! String)
            return ["status": "delivered", "result": ["session": ["key": "codex:a", "id": "a", "runtime": "codex"]]]
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertEqual(session.key, "codex:a")
        let next = try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "codex", cwd: "/fixture")
        XCTAssertNotEqual(ids[0], next.commandID)
    }

    func testUnknownCreationKeepsIdentityForExplicitReview() async throws {
        do {
            _ = try await SessionCreationCoordinator.create(
                hostID: "host", runtimeID: "claude", cwd: "/fixture", supportsReceipts: true
            ) { _, _ in ["status": "unknown", "detail": "Check the session list"] }
            XCTFail("Unknown is not success")
        } catch let SessionCreationError.unconfirmed(record, detail) {
            XCTAssertEqual(detail, "Check the session list")
            XCTAssertEqual(record, try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "claude", cwd: "/fixture"))
        }
    }

    func testRejectedCreationAllowsFreshIntent() async throws {
        let original = try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "codex", cwd: "")
        do {
            _ = try await SessionCreationCoordinator.create(
                hostID: "host", runtimeID: "codex", cwd: "", supportsReceipts: true
            ) { _, _ in ["status": "rejected", "detail": "Assistant unavailable"] }
            XCTFail("Rejected must show the cause")
        } catch CommandDeliveryError.rejected(let reason) {
            XCTAssertEqual(reason, "Assistant unavailable")
        }
        XCTAssertNotEqual(original.commandID, try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "codex", cwd: "").commandID)
    }

    func testLegacyHostDoesNotReceiveCreationID() async throws {
        _ = try await SessionCreationCoordinator.create(
            hostID: "host", runtimeID: "codex", cwd: "", supportsReceipts: false
        ) { _, params in
            XCTAssertNil(params["command_id"])
            return ["session": ["key": "codex:a", "id": "a", "runtime": "codex"]]
        }
    }

    func testAcceptedInputPollsWhileConnectionStaysOpen() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        client.hostCapabilities.commandReceipts = true
        defer { client.disconnect() }
        let store = ConversationStore(sessionKey: "codex:a", client: client, live: true, hostID: "fixture")
        store.recordPendingCommand(commandID: "input-one", text: "hello", localSeq: -1)
        let confirmed = expectation(description: "receipt polled without reconnect")
        store.commandStatusRequestForTesting = { id in
            XCTAssertEqual(id, "input-one")
            confirmed.fulfill()
            return ["status": "unknown", "detail": "Assistant did not confirm input"]
        }
        store.beginProvisionalWorking()
        store.applyCommandStatus(commandID: "input-one", status: "accepted")
        await fulfillment(of: [confirmed], timeout: 4)
        XCTAssertNil(store.provisionalWorkingSince)
        let records = PendingCommandStore.load(hostID: "fixture")
        XCTAssertEqual(records.first?.delivery, .needsReview)
        XCTAssertEqual(records.first?.failureDetail, "Assistant did not confirm input")
        await store.stop()
    }

    func testQueuedTextWaitsUntilEarlierMessageSettles() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        client.hostCapabilities.commandReceipts = true
        defer { client.disconnect() }
        let store = ConversationStore(sessionKey: "codex:a", client: client, live: true, hostID: "fixture")
        var sent: [String] = []
        store.inputRequestForTesting = { params in
            sent.append(params["text"] as? String ?? "")
            return ["status": "accepted"]
        }
        var released = false
        store.commandStatusRequestForTesting = { id in
            ["status": id == "one" && released ? "delivered" : "accepted"]
        }
        let firstSeq = store.enqueueLocalUser("first", commandID: "one")
        store.recordPendingCommand(commandID: "one", text: "first", localSeq: firstSeq)
        try await store.sendText("first", commandID: "one")
        store.applyCommandStatus(commandID: "one", status: "accepted")
        let secondSeq = store.enqueueLocalUser("second", commandID: "two")
        store.recordPendingCommand(commandID: "two", text: "second", localSeq: secondSeq)
        let second = Task { try await store.sendText("second", commandID: "two") }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sent, ["first"], "A later message must wait while the earlier one is confirming")
        XCTAssertEqual(store.queuedOutboundCount, 1)
        released = true
        try await second.value
        XCTAssertEqual(sent, ["first", "second"])
        XCTAssertEqual(store.queuedOutboundCount, 0)
        await store.stop()
    }

    func testExpiredCreationOnlyQueriesStatus() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let old = PendingSessionCreation(commandID: "old", hostID: "host", runtimeID: "codex", cwd: "", createdAt: Date(timeIntervalSince1970: 1))
        try JSONEncoder().encode([old]).write(to: scratch.appendingPathComponent("creations.json"))
        do {
            _ = try await SessionCreationCoordinator.create(hostID: "host", runtimeID: "codex", cwd: "", supportsReceipts: true) { method, _ in
                XCTAssertEqual(method, WireProtocol.mCommandStatus)
                return ["status": "unseen"]
            }
            XCTFail("An expired receipt must not become a new launch")
        } catch let SessionCreationError.unconfirmed(record, _) { XCTAssertEqual(record.commandID, "old") }
    }

    func testHostAndProjectIsolationAndNegotiation() throws {
        let first = try PendingSessionCreationStore.begin(hostID: "one", runtimeID: "codex", cwd: "/a")
        XCTAssertNotEqual(first, try PendingSessionCreationStore.begin(hostID: "two", runtimeID: "codex", cwd: "/a"))
        XCTAssertNotEqual(first, try PendingSessionCreationStore.begin(hostID: "one", runtimeID: "codex", cwd: "/b"))
        let caps = try JSONDecoder().decode(HostCapabilities.self, from: Data("{\"session_create_receipts\":true}".utf8))
        XCTAssertTrue(caps.sessionCreateReceipts)
        XCTAssertFalse(HostCapabilities.empty.sessionCreateReceipts)
    }
}
