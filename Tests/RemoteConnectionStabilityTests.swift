import Foundation
import Network
import XCTest
@testable import Corral

/// Same-machine / LAN connections must not drop (owner requirement 2026-10-05;
/// `cli/docs/REMOTE_KNOWLEDGE_BASE.md` "Same-machine and LAN connections never drop").
final class RemoteConnectionStabilityTests: XCTestCase {
    // MARK: - Ordered sending

    /// Requests fired from many tasks at once must reach the socket in counter
    /// order; the host drops the channel on the first out-of-order frame.
    func testConcurrentRequestsLeaveThePlaneInCounterOrder() async throws {
        let total = 400
        let server = try OrderedFrameServer(expected: total)
        defer { server.stop() }
        let port = try await server.start()

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)")))
        socket.resume()
        let plane = PlaneIO(win: HandshakeRace.Win(
            webSocket: socket,
            urlSession: session,
            channelID: WireProtocol.zeroChannel,
            secureChannel: SecureChannel(
                sendKey: Data(repeating: 1, count: 32),
                recvKey: Data(repeating: 2, count: 32),
                peerStaticPublic: Data(repeating: 3, count: 32)
            ),
            transport: .local,
            localHint: nil
        ), budget: PlaneOutgoingBudget(maxQueuedBytes: 4 * 1024 * 1024, maxQueuedFrames: 1_024))
        defer {
            plane.stop()
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<(total / 8) {
                        try? plane.enqueue(["t": "req", "id": worker * 1000 + index, "m": "x", "p": [:]], compress: false)
                    }
                }
            }
        }

        let counters = try await server.counters(timeout: 10)
        XCTAssertEqual(counters, Array(0..<UInt64(total)))
    }

    func testRequestsCarryTheProcessInstanceID() {
        XCTAssertEqual(WireProtocol.clientInstanceKey, "ci")
        XCTAssertFalse(RemoteClient.clientInstanceID.isEmpty)
        XCTAssertEqual(RemoteClient.clientInstanceID, RemoteClient.clientInstanceID)
    }

    // MARK: - Reconnect schedule

    func testFirstReconnectAfterADropIsImmediate() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 1, hasLocalCandidates: true), 0)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 1, hasLocalCandidates: false), 0)
    }

    func testLocalBackoffStaysShort() {
        let delays = (1...10).map { ReconnectBackoff.delay(forAttempt: $0, hasLocalCandidates: true) }
        XCTAssertEqual(Array(delays.prefix(5)), [0, 0.5, 1, 2, 4])
        XCTAssertTrue(delays.allSatisfy { $0 <= ReconnectBackoff.localCap })
        // The old schedule summed to 15 s before the fifth attempt; now 3.5 s.
        XCTAssertLessThan(delays.prefix(4).reduce(0, +), 4)
    }

    func testRelayOnlyBackoffKeepsTheLongCap() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 20, hasLocalCandidates: false), ReconnectBackoff.relayCap)
    }

    // MARK: - Transient drop presentation

    func testBriefDropStaysConnectedThroughTheGrace() {
        let dropped = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(TransientDropPolicy.shouldShowReconnecting(droppedAt: dropped, now: dropped.addingTimeInterval(1.4)))
        XCTAssertTrue(TransientDropPolicy.shouldShowReconnecting(droppedAt: dropped, now: dropped.addingTimeInterval(1.5)))
        XCTAssertGreaterThan(TransientDropPolicy.requestWait, TransientDropPolicy.presentationGrace)
    }

    func testForegroundSyncLeavesTheConnectedBarToTheGrace() {
        XCTAssertTrue(TransientDropPolicy.syncKeepsConnectedBar(isConnectedBar: true))
        XCTAssertFalse(TransientDropPolicy.syncKeepsConnectedBar(isConnectedBar: false))
    }

    // MARK: - Same-machine loopback

    func testLoopbackIsRacedWhenAHintIsThisMachine() {
        let own: Set<String> = ["192.0.2.15", "198.51.100.4"]
        XCTAssertEqual(SameMachineHost.loopbackHint(for: ["192.0.2.15:8737"], ownAddresses: own), "127.0.0.1:8737")
        XCTAssertEqual(SameMachineHost.loopbackHint(for: ["ws://198.51.100.4:9000/x"], ownAddresses: own), "127.0.0.1:9000")
    }

    func testNoLoopbackForARemoteHost() {
        let own: Set<String> = ["192.0.2.15"]
        XCTAssertNil(SameMachineHost.loopbackHint(for: ["192.0.2.20:8737"], ownAddresses: own))
        XCTAssertNil(SameMachineHost.loopbackHint(for: ["192.0.2.15:8737"], ownAddresses: []))
    }

    @MainActor
    func testLoopbackLeadsAndDoesNotEatTheLanBudget() throws {
        let hints = ["192.0.2.15:8737", "198.51.100.4:8737", "203.0.113.9:8737"]
        guard SameMachineHost.interfaceAddresses().contains(where: { !$0.hasPrefix("127.") }) else {
            throw XCTSkip("needs a non-loopback interface")
        }
        let own = SameMachineHost.interfaceAddresses().first { !$0.hasPrefix("127.") } ?? ""
        let host = HostInfo(
            hostID: "h",
            name: "h",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: nil,
            localHints: ["\(own):8737"] + hints
        )
        let urls = host.connectCandidates(includeLocal: true).compactMap { $0.url?.absoluteString }
        #if os(macOS)
        XCTAssertEqual(urls.first, "ws://127.0.0.1:8737")
        XCTAssertEqual(urls.count, 4, "loopback plus the usual three LAN hints")
        #else
        XCTAssertFalse(urls.contains("ws://127.0.0.1:8737"))
        #endif
    }

    // MARK: - Bounded ordered outgoing admission (memory slice 2026-10-25)

    func testReservedFramesCountAgainstTheFrameCeiling() {
        let outbox = PlaneOutbox(budget: PlaneOutgoingBudget(maxQueuedBytes: 1_000_000, maxQueuedFrames: 2))
        let failures = FailureCounter()
        XCTAssertEqual(admit(outbox, bytes: 10, failures: failures), .admitted)
        XCTAssertEqual(admit(outbox, bytes: 10, failures: failures), .admitted)
        XCTAssertEqual(outbox.depth.frames, 2)

        XCTAssertEqual(admit(outbox, bytes: 10, failures: failures), .overloaded)
        XCTAssertEqual(failures.count, 2, "Every admitted frame is failed exactly once")
        XCTAssertEqual(outbox.depth.frames, 0)
        XCTAssertTrue(outbox.isStopped)
        XCTAssertEqual(admit(outbox, bytes: 10, failures: failures), .overloaded)
    }

    func testByteCeilingIncludesTheInFlightFrame() async {
        let outbox = PlaneOutbox(budget: PlaneOutgoingBudget(maxQueuedBytes: 1_000, maxQueuedFrames: 10))
        let failures = FailureCounter()
        XCTAssertEqual(admit(outbox, bytes: 400, failures: failures), .admitted)
        XCTAssertEqual(admit(outbox, bytes: 400, failures: failures), .admitted)

        // Popping a frame only moves it to the writer; its bytes stay counted.
        let inFlight = await outbox.next()
        XCTAssertNotNil(inFlight)
        XCTAssertEqual(outbox.depth.bytes, 800)
        XCTAssertEqual(admit(outbox, bytes: 300, failures: failures), .overloaded)
        XCTAssertEqual(failures.count, 2)

        if let inFlight { outbox.complete(inFlight) }
        XCTAssertEqual(failures.count, 2, "Completing a settled frame cannot settle it twice")
    }

    func testOneLegalMaximumFrameFitsAnEmptyQueue() {
        let standard = PlaneOutbox(budget: .standard)
        XCTAssertEqual(standard.reserve(bytes: WireProtocol.maxFrameBytes), .admitted)
        standard.cancelReservation(bytes: WireProtocol.maxFrameBytes)
        XCTAssertEqual(standard.depth.frames, 0)

        let tight = PlaneOutbox(budget: PlaneOutgoingBudget(maxQueuedBytes: 1_024, maxQueuedFrames: 8))
        XCTAssertEqual(tight.reserve(bytes: 1_024), .admitted)
        tight.cancelReservation(bytes: 1_024)
        XCTAssertEqual(tight.reserve(bytes: 1_025), .overloaded)
    }

    func testStopFailsEveryQueuedFrameExactlyOnce() {
        let outbox = PlaneOutbox(budget: PlaneOutgoingBudget(maxQueuedBytes: 10_000, maxQueuedFrames: 8))
        let failures = FailureCounter()
        for _ in 0..<3 { _ = admit(outbox, bytes: 100, failures: failures) }

        outbox.stop()
        XCTAssertEqual(failures.count, 3)
        outbox.stop()
        XCTAssertEqual(failures.count, 3, "A repeated stop has no additional outcome")
        XCTAssertEqual(outbox.reserve(bytes: 1), .stopped)
        XCTAssertEqual(outbox.depth.frames, 0)
    }

    func testCompletedFramesAreNotFailedAgainOnStop() async {
        let outbox = PlaneOutbox(budget: PlaneOutgoingBudget(maxQueuedBytes: 10_000, maxQueuedFrames: 8))
        let failures = FailureCounter()
        _ = admit(outbox, bytes: 100, failures: failures)
        _ = admit(outbox, bytes: 100, failures: failures)
        for _ in 0..<2 {
            guard let frame = await outbox.next() else {
                XCTFail("missing frame")
                return
            }
            outbox.complete(frame)
        }
        XCTAssertEqual(outbox.depth.frames, 0)

        outbox.stop()
        XCTAssertEqual(failures.count, 0, "Delivered frames are not reported as failures")
        let next = await outbox.next()
        XCTAssertNil(next)
    }

    func testSendFailureSettlesTheInFlightAndQueuedFramesOnce() async {
        let outbox = PlaneOutbox(budget: PlaneOutgoingBudget(maxQueuedBytes: 10_000, maxQueuedFrames: 8))
        let failures = FailureCounter()
        _ = admit(outbox, bytes: 100, failures: failures)
        _ = admit(outbox, bytes: 100, failures: failures)
        let inFlight = await outbox.next()

        outbox.close(with: PlaneIOError.overloaded)
        XCTAssertEqual(failures.count, 2, "The in-flight frame and the queued frame both fail once")
        if let inFlight { outbox.complete(inFlight) }
        XCTAssertEqual(failures.count, 2)
        let next = await outbox.next()
        XCTAssertNil(next)
    }

    func testOverloadResetsThePlaneInsteadOfDroppingAnEncryptedFrame() async throws {
        let server = try OrderedFrameServer(expected: 1)
        defer { server.stop() }
        let port = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)")))
        socket.resume()
        let plane = PlaneIO(win: HandshakeRace.Win(
            webSocket: socket,
            urlSession: session,
            channelID: WireProtocol.zeroChannel,
            secureChannel: SecureChannel(
                sendKey: Data(repeating: 1, count: 32),
                recvKey: Data(repeating: 2, count: 32),
                peerStaticPublic: Data(repeating: 3, count: 32)
            ),
            transport: .local,
            localHint: nil
        ), budget: PlaneOutgoingBudget(maxQueuedBytes: 512, maxQueuedFrames: 8))
        defer {
            plane.stop()
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        let failures = FailureCounter()
        try plane.enqueue(["t": "req", "id": 1, "m": "a", "p": [:]], compress: false) { _ in failures.increment() }

        // Far beyond one legal frame for this budget: rejected, never sent.
        do {
            try plane.enqueue(["t": "req", "id": 2, "m": "b", "p": ["blob": String(repeating: "x", count: 2_000)]], compress: false) { _ in failures.increment() }
            XCTFail("An oversized frame must be rejected")
        } catch {
            XCTAssertEqual(error as? PlaneIOError, .overloaded)
        }
        XCTAssertEqual(failures.count, 1, "The queued frame is failed instead of delivered")
        XCTAssertEqual(plane.outboxDepth.frames, 0)
        do {
            try plane.enqueue(["t": "req", "id": 3, "m": "c", "p": [:]], compress: false)
            XCTFail("A reset plane must not accept more frames")
        } catch {
            XCTAssertEqual(error as? PlaneIOError, .overloaded)
        }
        XCTAssertEqual(failures.count, 1, "Reset outcomes are exactly once")
    }

    @MainActor
    func testStoppedPlaneRejectsADelayedProducer() throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        _ = client.installPlaneForTesting(isControl: true)
        let plane = try XCTUnwrap(client.controlPlane)
        plane.stop()
        do {
            try plane.enqueue(["t": "req", "id": 1, "m": "late", "p": [:]], compress: false)
            XCTFail("A replaced plane must not accept frames")
        } catch {
            XCTAssertEqual(error as? PlaneIOError, .stopped)
        }
    }

    private func admit(_ outbox: PlaneOutbox, bytes: Int, failures: FailureCounter) -> PlaneAdmission {
        let admission = outbox.reserve(bytes: bytes)
        guard admission == .admitted else { return admission }
        let frame = PlaneOutbox.Frame(data: Data(repeating: 7, count: bytes)) { _ in
            failures.increment()
        }
        outbox.commit(frame, estimatedBytes: bytes)
        return admission
    }
}

/// Thread-safe callback count: failure handlers run off the calling thread.
private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Minimal WebSocket server recording the 8-byte counter of each DATA frame.
private final class OrderedFrameServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ordered-frame-server")
    private let expected: Int
    private var received: [UInt64] = []
    private var waiter: CheckedContinuation<[UInt64], Error>?

    init(expected: Int) throws {
        self.expected = expected
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let gate = OneShotThrowingContinuation(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: gate.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error): gate.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    func counters(timeout: TimeInterval) async throws -> [UInt64] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt64], Error>) in
            queue.async {
                if self.received.count >= self.expected {
                    continuation.resume(returning: self.received)
                    return
                }
                self.waiter = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let waiter = self.waiter else { return }
                    self.waiter = nil
                    waiter.resume(returning: self.received)
                }
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let frame = try? WireFrame.decode(data), frame.type == WireProtocol.frameData {
                let counter = frame.payload.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                self.received.append(counter)
                if self.received.count >= self.expected, let waiter = self.waiter {
                    self.waiter = nil
                    waiter.resume(returning: self.received)
                }
            }
            self.receive(on: connection)
        }
    }
}
