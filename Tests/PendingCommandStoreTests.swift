import XCTest
@testable import Corral

@MainActor
final class PendingCommandStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        PendingCommandStore.directoryOverride = tempDir
    }

    override func tearDown() async throws {
        PendingCommandStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testHumanCauseDecodesFromBothReceiptShapes() throws {
        let direct = CommandStatusResponse.receipt(from: ["status": "rejected", "message": "Could not resume"])
        XCTAssertEqual(direct?.detail, "Could not resume")
        let nested = CommandStatusResponse.receipt(from: ["receipt": ["status": "unknown", "message": "Partial input"]])
        XCTAssertEqual(nested?.detail, "Partial input")
        let decoded = try JSONDecoder().decode(CommandStatusResponse.self,
            from: Data(#"{"status":"rejected","message":"Host cause"}"#.utf8))
        XCTAssertEqual(decoded.detail, "Host cause")
        XCTAssertEqual(PendingCommandStore.hostStatusAfterSendFailure(CommandDeliveryError.unconfirmed("Unknown")), "unknown")
        XCTAssertEqual(PendingCommandStore.hostStatusAfterSendFailure(CommandDeliveryError.rejected("No")), "rejected")
    }

    func testTransportFailureKeepsDurableRecordAsNeedsReview() {
        let record = PendingCommandRecord(
            commandID: "cmd-1",
            hostID: "host-a",
            sessionKey: "codex:x",
            text: "hello",
            localSeq: 3,
            delivery: .pending,
            createdAt: Date()
        )
        PendingCommandStore.upsert(record)

        let transport = RemoteClient.ConnectionError.timeout
        let status = PendingCommandStore.hostStatusAfterSendFailure(transport)
        XCTAssertEqual(status, "unknown")
        XCTAssertFalse(PendingCommandStore.isAuthoritativeHostRejection(transport))

        let delivery = PendingCommandStore.delivery(fromHostStatus: status)
        PendingCommandStore.updateDelivery(hostID: "host-a", commandID: "cmd-1", delivery: delivery)

        let unresolved = PendingCommandStore.unresolved(hostID: "host-a", sessionKey: "codex:x")
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved.first?.commandID, "cmd-1")
        XCTAssertEqual(unresolved.first?.delivery, .needsReview)
    }

    func testAuthoritativeRejectionRemovesDurableRecord() {
        let record = PendingCommandRecord(
            commandID: "cmd-2",
            hostID: "host-a",
            sessionKey: "codex:x",
            text: "nope",
            localSeq: 4,
            delivery: .pending,
            createdAt: Date()
        )
        PendingCommandStore.upsert(record)

        let remote = RemoteCallError(code: WireProtocol.eUsage, message: "bad", hint: "")
        XCTAssertTrue(PendingCommandStore.isAuthoritativeHostRejection(remote))
        let status = PendingCommandStore.hostStatusAfterSendFailure(remote)
        XCTAssertEqual(status, "rejected")

        let delivery = PendingCommandStore.delivery(fromHostStatus: status)
        PendingCommandStore.updateDelivery(hostID: "host-a", commandID: "cmd-2", delivery: delivery)

        XCTAssertTrue(PendingCommandStore.unresolved(hostID: "host-a", sessionKey: "codex:x").isEmpty)
        XCTAssertTrue(PendingCommandStore.load(hostID: "host-a", sessionKey: "codex:x").isEmpty)
    }

    func testNeedsReviewSurvivesAppRestartLoad() {
        PendingCommandStore.upsert(
            PendingCommandRecord(
                commandID: "cmd-keep",
                hostID: "host-b",
                sessionKey: "pi:1",
                text: "retry me",
                localSeq: 1,
                delivery: .needsReview,
                createdAt: Date()
            )
        )
        // Simulate process restart by clearing override path identity via reload.
        let again = PendingCommandStore.unresolved(hostID: "host-b", sessionKey: "pi:1")
        XCTAssertEqual(again.map(\.commandID), ["cmd-keep"])
        XCTAssertEqual(again.first?.delivery, .needsReview)
    }
}
