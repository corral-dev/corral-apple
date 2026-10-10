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
        ))
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
