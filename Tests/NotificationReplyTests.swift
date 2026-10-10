import Foundation
import UserNotifications
import XCTest
@testable import Corral

@MainActor
final class NotificationReplyTests: XCTestCase {
    private final class Client {
        let hostID: String
        init(_ hostID: String) { self.hostID = hostID }
    }

    @MainActor
    private final class Harness {
        var hosts = ["A", "B"].map { HostInfo(hostID: $0, name: $0, publicKeyHex: "") }
        var client: Client? = Client("A")
        var connectedHostID: String? = "A"
        var connectCalls: [String] = []
        var sent: [(String, [String: Any])] = []
        var receipts = true
        var failSend = false
        var onConnect: ((Harness) -> Void)?

        func reply(hostID: String? = "B", key: String? = "session", text: String = "reply") async {
            await NotificationReply.send(
                hostID: hostID, sessionKey: key, text: text,
                resolveHost: { id in self.hosts.first { $0.hostID == id } },
                isConnected: { self.connectedHostID == $0.hostID && self.client != nil },
                connect: { host in
                    self.connectCalls.append(host.hostID)
                    self.client = Client(host.hostID)
                    self.connectedHostID = host.hostID
                    self.onConnect?(self)
                },
                currentClient: { self.client },
                supportsReceipts: { _ in self.receipts },
                send: { client, params in
                    self.sent.append((client.hostID, params))
                    if self.failSend { throw RemoteClient.ConnectionError.timeout }
                }
            )
        }
    }

    func testReplySwitchesFromCurrentHostToNotificationOwner() async {
        let harness = Harness()
        await harness.reply()
        XCTAssertEqual(harness.connectCalls, ["B"])
        XCTAssertEqual(harness.sent.first?.0, "B")
        XCTAssertEqual(harness.sent.first?.1["key"] as? String, "session")
        XCTAssertEqual(harness.sent.first?.1["text"] as? String, "reply")
        XCTAssertNotNil(harness.sent.first?.1["command_id"] as? String)
    }

    func testReplyDoesNotReconnectWhenOwnerIsAlreadyConnected() async {
        let harness = Harness()
        await harness.reply(hostID: "A")
        XCTAssertTrue(harness.connectCalls.isEmpty)
        XCTAssertEqual(harness.sent.first?.0, "A")
    }

    func testMissingOrRemovedHostNeverUsesCurrentClient() async {
        let harness = Harness()
        await harness.reply(hostID: nil)
        await harness.reply(hostID: "unpaired")
        XCTAssertTrue(harness.connectCalls.isEmpty)
        XCTAssertTrue(harness.sent.isEmpty)
    }

    func testFailedConnectionNeverUsesPreviousHost() async {
        let harness = Harness()
        harness.onConnect = { $0.connectedHostID = "A"; $0.client = Client("A") }
        await harness.reply()
        XCTAssertTrue(harness.sent.isEmpty)
    }

    func testPairingRemovedDuringConnectRejectsReply() async {
        let harness = Harness()
        harness.onConnect = { $0.hosts.removeAll { $0.hostID == "B" } }
        await harness.reply()
        XCTAssertTrue(harness.sent.isEmpty)
    }

    func testLegacyHostGetsReplyWithoutReceiptID() async {
        let harness = Harness()
        harness.receipts = false
        await harness.reply()
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertNil(harness.sent.first?.1["command_id"])
    }

    func testEachReplyHasUniqueIDAndAmbiguousFailureIsNotRetried() async {
        let harness = Harness()
        harness.failSend = true
        await harness.reply()
        await harness.reply()
        XCTAssertEqual(harness.sent.count, 2)
        let first = harness.sent[0].1["command_id"] as? String
        let second = harness.sent[1].1["command_id"] as? String
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
    }

    func testSendIgnoresEmptyTextTapPayload() async {
        // A normal body tap carries empty text; the send path must neither
        // connect nor emit input for it (navigation owns that tap).
        let harness = Harness()
        await harness.reply(text: "")
        XCTAssertTrue(harness.connectCalls.isEmpty)
        XCTAssertTrue(harness.sent.isEmpty)
    }

    func testRouteReplyRequiresTextAndIdentifiers() {
        XCTAssertEqual(
            NotificationReply.route(actionIdentifier: "REPLY", hostID: "B", sessionKey: "s", text: "hi"),
            .reply(hostID: "B", sessionKey: "s", text: "hi")
        )
        XCTAssertEqual(
            NotificationReply.route(actionIdentifier: "REPLY", hostID: "B", sessionKey: "s", text: ""),
            .ignore
        )
        XCTAssertEqual(
            NotificationReply.route(actionIdentifier: "REPLY", hostID: "", sessionKey: "s", text: "hi"),
            .ignore
        )
        XCTAssertEqual(
            NotificationReply.route(actionIdentifier: "REPLY", hostID: "B", sessionKey: nil, text: "hi"),
            .ignore
        )
    }

    func testRouteDefaultTapOpensWithoutSending() {
        XCTAssertEqual(
            NotificationReply.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                hostID: "B", sessionKey: "s", text: ""
            ),
            .open(hostID: "B", sessionKey: "s")
        )
        XCTAssertEqual(
            NotificationReply.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                hostID: nil, sessionKey: "s", text: ""
            ),
            .ignore
        )
        XCTAssertEqual(
            NotificationReply.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                hostID: "B", sessionKey: "", text: ""
            ),
            .ignore
        )
    }

    func testRouteDismissAndUnknownActionsAreIgnored() {
        XCTAssertEqual(
            NotificationReply.route(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                hostID: "B", sessionKey: "s", text: ""
            ),
            .ignore
        )
        XCTAssertEqual(
            NotificationReply.route(actionIdentifier: "WHATEVER", hostID: "B", sessionKey: "s", text: "hi"),
            .ignore
        )
    }

    func testPendingStoreCollapsesIdenticalTaps() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "B", sessionKey: "s")
        pending.store(hostID: "B", sessionKey: "s")
        XCTAssertEqual(pending.request, NotificationOpenRequest(hostID: "B", sessionKey: "s"))
    }

    func testPendingStoreRejectsEmptyIdentifiers() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "", sessionKey: "s")
        pending.store(hostID: "B", sessionKey: "")
        XCTAssertNil(pending.request)
    }

    func testPendingConsumeMatchesExactly() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "B", sessionKey: "s")
        XCTAssertFalse(pending.consume(hostID: "B", sessionKey: "other"))
        XCTAssertNotNil(pending.request)
        XCTAssertTrue(pending.consume(hostID: "B", sessionKey: "s"))
        XCTAssertNil(pending.request)
    }

    func testPendingSessionKeyIsHostScoped() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "B", sessionKey: "s")
        XCTAssertNil(pending.sessionKey(for: "A"))
        XCTAssertEqual(pending.sessionKey(for: "B"), "s")
    }

    func testPendingClearKeepsUnrelatedRequests() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "B", sessionKey: "s")
        pending.clear(hostID: "A")
        XCTAssertNotNil(pending.request)
        pending.clear(hostID: "B")
        XCTAssertNil(pending.request)
    }

    func testTicketBumpsOnlyOnChange() {
        var pending = PendingNotificationOpen()
        XCTAssertEqual(pending.ticket, 0)
        pending.store(hostID: "B", sessionKey: "s")
        XCTAssertEqual(pending.ticket, 1)
        pending.store(hostID: "B", sessionKey: "s")
        XCTAssertEqual(pending.ticket, 1)
        pending.store(hostID: "B", sessionKey: "other")
        XCTAssertEqual(pending.ticket, 2)
        XCTAssertTrue(pending.consume(hostID: "B", sessionKey: "other"))
        pending.store(hostID: "B", sessionKey: "other")
        XCTAssertEqual(pending.ticket, 3)
    }

    func testConsumeThenIdenticalTapRoutesAgain() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "B", sessionKey: "s")
        XCTAssertTrue(pending.consume(hostID: "B", sessionKey: "s"))
        XCTAssertNil(pending.request)
        pending.store(hostID: "B", sessionKey: "s")
        XCTAssertEqual(pending.request, NotificationOpenRequest(hostID: "B", sessionKey: "s"))
    }

    func testShouldRouteNotification() {
        XCTAssertFalse(NotificationReply.shouldRouteNotification(ticket: 1, routedTicket: 1))
        XCTAssertTrue(NotificationReply.shouldRouteNotification(ticket: 2, routedTicket: 1))
        XCTAssertTrue(NotificationReply.shouldRouteNotification(ticket: 1, routedTicket: nil))
    }
}
