import Foundation
import XCTest
@testable import Corral

@MainActor
final class RemoteClientLifecycleTests: XCTestCase {
    func testUnconfirmedDataSocketIsNotReportedAsHealthy() {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        _ = client.installPlaneForTesting(isControl: true)
        let data = client.installPlaneForTesting(isControl: false)
        XCTAssertTrue(client.hasDataPlane)
        XCTAssertFalse(client.diagnosticState.dataAttached)
        client.dataPlaneConfirmed = true
        XCTAssertTrue(client.diagnosticState.dataAttached)
        data.fail()
        XCTAssertFalse(client.dataPlaneConfirmed)
        XCTAssertFalse(client.diagnosticState.dataAttached)
    }

    func testDiagnosticsNeverRecordResponseBodiesOrStalePlaneFailures() throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 7, count: 32))
        defer { client.disconnect() }
        let old = client.installPlaneForTesting(isControl: true)
        _ = client.installPlaneForTesting(isControl: true)
        let failures = client.diagnostics.counters["planeFailed", default: 0]
        old.fail()
        XCTAssertEqual(client.diagnostics.counters["planeFailed", default: 0], failures)
        client.dispatch(["t": "res", "id": "bad", "d": ["secret": "CHAT_SECRET", "code": "PAIR_SECRET"]])
        let report = client.diagnostics.report(state: client.diagnosticState)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("CHAT_SECRET"))
        XCTAssertFalse(json.contains("PAIR_SECRET"))
        XCTAssertEqual(report.counters["malformedResponse"], 1)
    }

    func testDiagnosticRetentionAndResponseCountersAreBounded() {
        let recorder = ClientDiagnostics()
        for _ in 0..<300 { recorder.record(.orphanResponse) }
        for _ in 0..<2_000 { recorder.record(.responseReceived) }
        XCTAssertEqual(recorder.events.count, 128)
        XCTAssertEqual(recorder.events.first?.sequence, 173)
        XCTAssertEqual(recorder.counters["responseReceived"], 2_000)
        XCTAssertEqual(recorder.counters["orphanResponse"], 300)
    }

    func testDiagnosticPersistenceUsesExplicitTemporaryDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ClientDiagnostics(directory: directory)
        let state = ClientDiagnosticState(connection: "ready", transport: "local", dataAttached: true,
            pendingRequests: 2, subscriptions: 3, reconnectAttempt: 0, dataRebindAttempt: 0, lastReceiveAge: 1)
        recorder.record(.raceWon, durationMs: 12)
        recorder.persist(state: state, force: true)
        let destination = directory.appendingPathComponent("client-\(ProcessInfo.processInfo.processIdentifier)-\(recorder.clientRun).json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: destination.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let report = try JSONDecoder().decode(ClientDiagnosticReport.self, from: Data(contentsOf: destination))
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.state.pendingRequests, 2)
        XCTAssertEqual(report.events.last?.event, .raceWon)
    }

    func testOldControlFailureCannotDisconnectReplacement() {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        let old = client.installPlaneForTesting(isControl: true)
        let current = client.installPlaneForTesting(isControl: true)

        old.fail()
        XCTAssertEqual(client.state, .ready)
        current.fail()
        XCTAssertEqual(client.state, .disconnected)
    }

    func testOldDataFailureCannotRemoveReplacement() {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        _ = client.installPlaneForTesting(isControl: true)
        let old = client.installPlaneForTesting(isControl: false)
        let current = client.installPlaneForTesting(isControl: false)

        old.fail()
        XCTAssertTrue(client.hasDataPlane)
        XCTAssertEqual(client.state, .ready)
        current.fail()
        XCTAssertFalse(client.hasDataPlane)
        XCTAssertEqual(client.state, .ready)
    }

    func testOnlyReplacementControlFramesReachSubscribers() async {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        let old = client.installPlaneForTesting(isControl: true)
        let events = client.subscribeAll()
        let current = client.installPlaneForTesting(isControl: true)
        old.receive(["t": "evt", "c": "old", "d": [:]])
        current.receive(["t": "evt", "c": "current", "d": [:]])

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.channel, "current")
    }

    func testOnlyReplacementDataFramesReachSubscribers() async {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        _ = client.installPlaneForTesting(isControl: true)
        let old = client.installPlaneForTesting(isControl: false)
        let events = client.subscribeAll()
        let current = client.installPlaneForTesting(isControl: false)
        old.receive(["t": "evt", "c": "old", "d": [:]])
        current.receive(["t": "evt", "c": "current", "d": [:]])

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.channel, "current")
    }

    func testCallbacksAfterDisconnectCannotReviveClient() {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        let control = client.installPlaneForTesting(isControl: true)
        let data = client.installPlaneForTesting(isControl: false)
        client.disconnect()
        control.fail()
        data.fail()
        XCTAssertEqual(client.state, .disconnected)
        XCTAssertFalse(client.hasDataPlane)
    }

    func testDataPlaneTeardownFailsOnlyItsPendingRequests() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        _ = client.installPlaneForTesting(isControl: true)
        let data = client.installPlaneForTesting(isControl: false)
        client.controlConfirmed = true
        client.dataPlaneConfirmed = true
        let dataCall = Task { _ = try await client.callRaw(WireProtocol.mSessionWatch, params: ["key": "k"]) }
        let controlCall = Task { _ = try await client.callRaw(WireProtocol.mSessionMarkRead, params: ["key": "k"]) }
        defer { controlCall.cancel() }
        for _ in 0..<200 where client.pendingRequests.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(client.pendingRequests.count, 2)

        data.fail()

        do {
            try await dataCall.value
            XCTFail("A request on the torn-down data plane must fail immediately")
        } catch RemoteClient.ConnectionError.notConnected {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(client.pendingRequests.count, 1, "The control-plane request stays pending")
    }
}
