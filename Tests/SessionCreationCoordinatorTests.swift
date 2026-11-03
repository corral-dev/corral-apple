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

    func testLostReplyDoesNotBlockANewCreationIntent() async throws {
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
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(session.key, "codex:a")
        let next = try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "codex", cwd: "/fixture")
        XCTAssertNotEqual(ids[0], next.commandID)
    }

    func testUnknownCreationIsRetainedWithoutBlockingANewIntent() async throws {
        do {
            _ = try await SessionCreationCoordinator.create(
                hostID: "host", runtimeID: "claude", cwd: "/fixture", supportsReceipts: true
            ) { _, _ in ["status": "unknown", "detail": "Check the session list"] }
            XCTFail("Unknown is not success")
        } catch let SessionCreationError.unconfirmed(record, detail) {
            XCTAssertEqual(detail, "Check the session list")
            let next = try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "claude", cwd: "/fixture")
            XCTAssertNotEqual(record.commandID, next.commandID)
            let records = try JSONDecoder().decode(
                [PendingSessionCreation].self,
                from: Data(contentsOf: scratch.appendingPathComponent("creations.json"))
            )
            XCTAssertEqual(records, [record, next], "Uncertain outcomes remain durable, not a create gate")
        }
    }

    func testRejectedCreationRemovesOnlyItsOwnRecord() async throws {
        let older = try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "codex", cwd: "")
        var rejectedID: String?
        do {
            _ = try await SessionCreationCoordinator.create(
                hostID: "host", runtimeID: "codex", cwd: "", supportsReceipts: true
            ) { _, params in
                rejectedID = params["command_id"] as? String
                return ["status": "rejected", "detail": "Assistant unavailable"]
            }
            XCTFail("Rejected must show the cause")
        } catch CommandDeliveryError.rejected(let reason) {
            XCTAssertEqual(reason, "Assistant unavailable")
        }
        XCTAssertNotNil(rejectedID)
        XCTAssertNotEqual(older.commandID, rejectedID)
        let remaining = try JSONDecoder().decode(
            [PendingSessionCreation].self,
            from: Data(contentsOf: scratch.appendingPathComponent("creations.json"))
        )
        XCTAssertEqual(remaining, [older])
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

    func testReceiptedSendRetriesTransportFailureWithoutChangingIdentity() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        client.hostCapabilities.commandReceipts = true
        defer { client.disconnect() }
        let store = ConversationStore(sessionKey: "codex:a", client: client, live: false, hostID: "fixture")
        var identities: [String] = []
        store.inputRequestForTesting = { params in
            identities.append(params["command_id"] as? String ?? "")
            if identities.count == 1 { throw RemoteClient.ConnectionError.notConnected }
            return ["status": "delivered"]
        }
        try await store.sendText("resume and deliver", commandID: "one-intent")
        XCTAssertEqual(identities, ["one-intent", "one-intent"])
        await store.stop()
    }

    func testLegacySendDoesNotRetryAnAmbiguousTransportFailure() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        let store = ConversationStore(sessionKey: "codex:a", client: client, live: true)
        var attempts = 0
        store.inputRequestForTesting = { _ in attempts += 1; throw URLError(.timedOut) }
        do {
            try await store.sendText("only once")
            XCTFail("Legacy sends cannot safely retry an ambiguous outcome")
        } catch is URLError {}
        XCTAssertEqual(attempts, 1)
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
        let releasedAt = ContinuousClock.now
        released = true
        try await second.value
        XCTAssertLessThan(releasedAt.duration(to: .now), .seconds(3), "A queued send must not wait for its own receipt")
        XCTAssertEqual(sent, ["first", "second"])
        XCTAssertEqual(store.queuedOutboundCount, 0)
        await store.stop()
    }

    func testUnconfirmableAcceptedBubblesDoNotHoldBackNewSends() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        client.hostCapabilities.commandReceipts = true
        defer { client.disconnect() }
        let store = ConversationStore(sessionKey: "codex:a", client: client, live: true, hostID: "fixture")
        var sent: [String] = []
        store.inputRequestForTesting = { params in
            sent.append(params["text"] as? String ?? "")
            return ["status": "accepted"]
        }
        store.commandStatusRequestForTesting = { _ in ["status": "accepted"] }
        // A host echo without a command identity: receipt polling can never settle it.
        let echoSeq = store.enqueueLocalUser("echo", commandID: nil)
        store.markLocalAccepted(seq: echoSeq)
        let start = ContinuousClock.now
        try await store.sendText("after echo", commandID: "fresh-one")
        XCTAssertEqual(sent, ["after echo"])
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "An identity-less accepted echo must not delay sends")
        // A tracked send accepted long ago (restored from the reopen cache) is stale too.
        let oldSeq = store.enqueueLocalUser("old", commandID: "old-one")
        store.markLocalAccepted(seq: oldSeq)
        store.ageLocalMessagesForTesting(by: 3600)
        let again = ContinuousClock.now
        try await store.sendText("after stale", commandID: "fresh-two")
        XCTAssertEqual(sent, ["after echo", "after stale"])
        XCTAssertLessThan(ContinuousClock.now - again, .seconds(1), "A stale accepted bubble must not delay sends")
        await store.stop()
    }

    func testExpiredCreationDoesNotHijackNewSessionOrAddPane() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let old = PendingSessionCreation(commandID: "old", hostID: "host", runtimeID: "pi", cwd: "/fixture", createdAt: Date(timeIntervalSince1970: 1))
        let url = scratch.appendingPathComponent("creations.json")
        try JSONEncoder().encode([old]).write(to: url)
        var ids: [String] = []
        // The shared coordinator serves New Session, Quick Start and Mac Add Pane.
        for index in 0..<3 {
            let session = try await SessionCreationCoordinator.create(
                hostID: "host", runtimeID: "pi", cwd: "/fixture", supportsReceipts: true
            ) { method, params in
                XCTAssertEqual(method, WireProtocol.mSessionNew)
                let id = try XCTUnwrap(params["command_id"] as? String)
                XCTAssertNotEqual(id, old.commandID)
                ids.append(id)
                return ["session": ["key": "pi:new-\(index)", "id": "new-\(index)", "runtime": "pi"]]
            }
            XCTAssertEqual(session.key, "pi:new-\(index)")
        }
        XCTAssertEqual(Set(ids).count, 3)
        let remaining = try JSONDecoder().decode([PendingSessionCreation].self, from: Data(contentsOf: url))
        XCTAssertEqual(remaining, [old], "A new intent must not replay or erase an uncertain older one")
    }

    func testAcceptedCreationPollsOnlyItsOwnIdentity() async throws {
        let old = try PendingSessionCreationStore.begin(hostID: "host", runtimeID: "pi", cwd: "/fixture")
        var id: String?
        let session = try await SessionCreationCoordinator.create(
            hostID: "host", runtimeID: "pi", cwd: "/fixture", supportsReceipts: true
        ) { method, params in
            let commandID = try XCTUnwrap(params["command_id"] as? String)
            XCTAssertNotEqual(commandID, old.commandID)
            if method == WireProtocol.mSessionNew {
                XCTAssertNil(id)
                id = commandID
                return ["status": "accepted"]
            }
            XCTAssertEqual(method, WireProtocol.mCommandStatus)
            XCTAssertEqual(commandID, id)
            return ["status": "delivered", "result": ["session": ["key": "pi:new", "id": "new", "runtime": "pi"]]]
        }
        XCTAssertEqual(session.key, "pi:new")
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
