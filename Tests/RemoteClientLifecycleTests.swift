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

    // MARK: - Bounded multicast delivery (memory slice 2026-10-25)

    func testEventSizingCountsLargeStringBodies() {
        let payload: [String: Any] = [
            "kind": "patch",
            "sessions": [["title": String(repeating: "x", count: 4_096)]],
        ]
        XCTAssertGreaterThan(RemoteEventSizing.estimatedBytes(of: payload), 4_096)
    }

    func testSlowSubscriberRetainsABoundedWindowAndOneResyncMarker() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        let events = client.subscribeAll()
        // The main actor is busy dispatching, so this consumer cannot drain yet.
        for index in 0..<100 {
            client.dispatch(["t": "evt", "c": "sessions", "d": ["kind": "patch", "index": index]])
        }
        XCTAssertEqual(client.diagnostics.counters["eventGap", default: 0], 1,
                       "One coalesced gap report for the flooded subscriber")
        XCTAssertEqual(client.diagnosticState.subscriptions, 1)

        let reader = resyncReader(events)
        let received = await reader.value

        XCTAssertEqual(received.count, 1, "Only the coalesced marker survives the flood")
        XCTAssertEqual(received.first?.data["resync"] as? Bool, true)
        XCTAssertGreaterThan(received.first?.data["dropped"] as? Int ?? 0, 0)
        client.disconnect()
    }

    func testGapMarkerArrivesOnTheChannelThatLostEvents() async {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        let events = client.subscribe(channel: "term:abc")
        for index in 0..<60 {
            client.dispatch(["t": "evt", "c": "term:abc", "d": ["kind": "output", "seq": index]])
        }
        let reader = resyncReader(events)
        let received = await reader.value

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.channel, "term:abc")
        XCTAssertEqual(received.last?.data["resync"] as? Bool, true)
        client.disconnect()
    }

    func testASlowChannelDoesNotGapAnIdleChannel() async {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        _ = client.subscribe(channel: "sessions")
        let fast = client.subscribe(channel: "session:k")
        for index in 0..<60 {
            client.dispatch(["t": "evt", "c": "sessions", "d": ["kind": "patch", "index": index]])
        }
        client.dispatch(["t": "evt", "c": "session:k", "d": ["kind": "attention", "attention": "unread"]])

        let first = await Task { @MainActor () -> RemoteEvent? in
            for await event in fast { return event }
            return nil
        }.value
        XCTAssertEqual(first?.channel, "session:k")
        XCTAssertEqual(first?.data["kind"] as? String, "attention")
    }

    func testGapRecoveryNotificationIsCoalesced() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        var ready = 0
        client.addReadyHandler { ready += 1 }
        _ = client.subscribe(channel: "sessions")

        for index in 0..<40 {
            client.dispatch(["t": "evt", "c": "sessions", "d": ["kind": "patch", "index": index]])
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(ready, 1, "One resync for the first gap")

        for index in 0..<40 {
            client.dispatch(["t": "evt", "c": "sessions", "d": ["kind": "patch", "index": index + 40]])
        }
        XCTAssertEqual(ready, 1, "A second gap within the spacing window is coalesced")
    }

    func testDisconnectFinishesBoundedSubscribers() async {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        let events = client.subscribeAll()
        client.disconnect()
        var received = 0
        for await _ in events { received += 1 }
        XCTAssertEqual(received, 0)
        XCTAssertEqual(client.diagnosticState.subscriptions, 0)
    }

    /// Collects events until the coalesced marker, or until the stream finishes.
    private func resyncReader(_ stream: AsyncStream<RemoteEvent>) -> Task<[RemoteEvent], Never> {
        Task { @MainActor in
            var received: [RemoteEvent] = []
            for await event in stream {
                received.append(event)
                if event.data["resync"] as? Bool == true { break }
                if received.count > RemoteEventDelivery.capacity + 1 { break }
            }
            return received
        }
    }
}
