import Foundation
import Network
import XCTest
@testable import Corral

@MainActor
final class ConnectionRecoveryTests: XCTestCase {
    func testEveryRetainedCandidateEventuallyGetsARace() {
        let hints = (1...7).map { "192.0.2.\($0):8737" }
        let host = HostInfo(hostID: "review", name: "review", publicKeyHex: String(repeating: "ab", count: 32),
                            relayURL: "wss://relay.example.com", localHints: hints, lastLocalHint: hints[0])
        var seen = Set<String>()
        for round in 0..<7 {
            let candidates = host.connectCandidates(round: round)
            let locals = candidates.filter { $0.transport == .local }
            XCTAssertLessThanOrEqual(locals.count, 3)
            XCTAssertEqual(candidates.filter { $0.transport == .relay }.count, 1)
            seen.formUnion(locals.compactMap { $0.url?.host })
        }
        XCTAssertEqual(seen.count, hints.count)
    }

    func testDataRecoveryNeverExhaustsAndDelayIsBounded() {
        XCTAssertTrue(DataPlaneRebindPolicy.shouldRetry(attempt: 1_000, controlReady: true, dataPlaneAttached: false))
        XCTAssertEqual(DataPlaneRebindPolicy.delay(forAttempt: 1_000), 30)
        XCTAssertFalse(DataPlaneRebindPolicy.shouldRetry(attempt: 1, controlReady: false, dataPlaneAttached: false))
        XCTAssertFalse(DataPlaneRebindPolicy.shouldRetry(attempt: 1, controlReady: true, dataPlaneAttached: true))
    }

    func testHandshakeAloneIsNotUsableThenAuthenticatedHelloIs() async throws {
        let server = try RecoveryHost()
        let host = try await server.start()
        defer { server.stop() }
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey())
        defer { client.disconnect() }
        try await client.connect(host: host)
        XCTAssertEqual(client.state, .ready)
        XCTAssertFalse(client.isUsable)
        XCTAssertEqual(client.diagnosticState.connection, "handshaking")
        _ = try await client.hello(name: "review")
        XCTAssertTrue(client.isUsable)
        XCTAssertEqual(client.diagnosticState.connection, "ready")
    }

    func testDiscoveryRecoversAHostWhoseSavedAddressIsDead() async throws {
        let server = try RecoveryHost()
        let actual = try await server.start()
        defer { server.stop() }
        let discovered = actual.localHints
        var stale = actual
        stale.localHints = ["127.0.0.1:1"]
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey(), addressDiscovery: { id in
            XCTAssertEqual(id, "review-fixture")
            return discovered
        })
        defer { client.disconnect() }
        try await client.connect(host: stale)
        _ = try await client.hello(name: "review")
        XCTAssertTrue(client.isUsable)
        XCTAssertEqual(client.activeTransport, .local)
    }

    func testWrongHostIdentityNeverConfirmsTheTransport() async throws {
        let server = try RecoveryHost()
        var host = try await server.start()
        host = HostInfo(hostID: "wrong-host", name: "review", publicKeyHex: host.publicKeyHex, localHints: host.localHints)
        defer { server.stop() }
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey())
        defer { client.disconnect() }
        try await client.connect(host: host)
        do { _ = try await client.hello(name: "review"); XCTFail("wrong host accepted") }
        catch RemoteClient.ConnectionError.invalidResponse { }
        XCTAssertFalse(client.isUsable)
    }

    func testRevokedPairingStopsRecoveryWithoutFalseReady() async throws {
        let server = try RecoveryHost(paired: false)
        let host = try await server.start()
        defer { server.stop() }
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey())
        defer { client.disconnect() }
        try await client.connect(host: host)
        do {
            _ = try await client.hello(name: "review")
            XCTFail("Revoked pairing cannot confirm a connection")
        } catch RemoteClient.ConnectionError.pairingRequired {
            client.recoverConnection(after: RemoteClient.ConnectionError.pairingRequired)
        }
        XCTAssertFalse(client.isUsable)
        XCTAssertFalse(client.allowReconnect)
        XCTAssertNotNil(client.terminalConnectionError)
        XCTAssertEqual(client.state, .disconnected)
    }

    func testHealthyPathChecksCoalesceAndKeepTheSocket() async throws {
        let server = try RecoveryHost()
        let host = try await server.start()
        defer { server.stop() }
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey())
        defer { client.disconnect() }
        try await client.connect(host: host)
        _ = try await client.hello(name: "review")
        let plane = client.controlPlane
        async let first = client.probeAndMigrateIfNeeded()
        async let second = client.probeAndMigrateIfNeeded()
        let outcomes = await (first, second)
        XCTAssertFalse(outcomes.0)
        XCTAssertFalse(outcomes.1)
        XCTAssertTrue(client.controlPlane === plane)
        XCTAssertTrue(client.isUsable)
        let count = await server.helloCount()
        XCTAssertEqual(count, 2, "One initial hello and one coalesced health check")
    }

    func testUpgradeIsConfirmedBeforeReplacingTheOldPath() async throws {
        let server = try RecoveryHost()
        let host = try await server.start()
        defer { server.stop() }
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey())
        defer { client.disconnect() }
        try await client.connect(host: host)
        _ = try await client.hello(name: "review")
        let old = client.controlPlane
        let win = try await RemoteClient.raceHandshakes(candidates: host.connectCandidates(),
            devicePrivateKey: client.devicePrivateKey, hostPublicKey: host.publicKeyData!, overallTimeout: 3)
        defer { win.close() }
        try await RemoteClient.validateUpgrade(win, hostID: host.hostID, name: "review")
        XCTAssertTrue(client.controlPlane === old)
        XCTAssertTrue(client.isUsable)
    }

    func testInitialFailureRecoversAndConfirmsBeforeNotifying() async throws {
        let server = try RecoveryHost(rejectFirst: true)
        let host = try await server.start()
        defer { server.stop() }
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey())
        client.lastHelloName = "review"
        defer { client.disconnect() }
        var notified = false
        client.addReadyHandler { XCTAssertTrue(client.isUsable); notified = true }
        do {
            try await client.connect(host: host)
            XCTFail("The first connection must fail")
        } catch {
            client.recoverConnection(after: error)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !notified && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(notified)
        XCTAssertTrue(client.isUsable)
    }
}

/// Real WebSocket and encrypted Corral frames, isolated from pairing/user data.
nonisolated private final class RecoveryHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "corral.recovery.fixture")
    private let listener: NWListener
    private let key = RemoteCryptoKeys.generatePrivateKey()
    private let paired: Bool
    private var rejectFirst: Bool
    private var hellos = 0
    private var connections: [NWConnection] = []

    init(paired: Bool = true, rejectFirst: Bool = false) throws {
        self.paired = paired
        self.rejectFirst = rejectFirst
        let parameters = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> HostInfo {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let gate = OneShotThrowingContinuation(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: gate.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error): gate.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                if rejectFirst { rejectFirst = false; connection.cancel(); return }
                let channel = Data(repeating: 1, count: 16)
                send(try! WireFrame.encode(type: WireProtocol.frameDeviceOpen, channelID: channel), on: connection)
                receive(on: connection, channel: channel, secure: nil)
            }
            listener.start(queue: queue)
        }
        let publicKey = try RemoteCryptoKeys.publicKey(from: key)
        return HostInfo(hostID: "review-fixture", name: "review", publicKeyHex: publicKey.map { String(format: "%02x", $0) }.joined(),
                        localHints: ["127.0.0.1:\(port)"])
    }

    func helloCount() async -> Int { await withCheckedContinuation { c in queue.async { c.resume(returning: self.hellos) } } }
    func stop() { queue.async { self.connections.forEach { $0.cancel() }; self.listener.cancel() } }

    private func send(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection, channel: Data, secure: SecureChannel?) {
        connection.receiveMessage { [self] data, _, _, error in
            guard let data, error == nil else { return }
            do {
                let frame = try WireFrame.decode(data)
                var nextSecure = secure
                if frame.type == WireProtocol.frameHello {
                    let eph = RemoteCryptoKeys.generatePrivateKey()
                    let ep = try RemoteCryptoKeys.publicKey(from: eph)
                    let ds = Data(frame.payload.prefix(32)), de = Data(frame.payload.suffix(32))
                    let ikm = try RemoteCryptoKeys.diffieHellman(privateKey: eph, peerPublic: de)
                        + RemoteCryptoKeys.diffieHellman(privateKey: key, peerPublic: ds)
                        + RemoteCryptoKeys.diffieHellman(privateKey: key, peerPublic: de)
                        + RemoteCryptoKeys.diffieHellman(privateKey: eph, peerPublic: ds)
                    let salt = de + ep
                    nextSecure = SecureChannel(sendKey: RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoH2D),
                        recvKey: RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoD2H), peerStaticPublic: ds)
                    send(try WireFrame.encode(type: WireProtocol.frameHello, channelID: channel, payload: ep), on: connection)
                } else if frame.type == WireProtocol.frameData, let secure {
                    let message = try WireMessage.unpack(secure.decrypt(frame.payload))
                    hellos += 1
                    let reply: [String: Any] = ["t": "res", "id": message["id"] ?? 0, "ok": true,
                        "d": ["paired": paired, "host_id": "review-fixture", "access": "readonly"]]
                    send(try WireFrame.encode(type: WireProtocol.frameData, channelID: channel,
                        payload: secure.encrypt(WireMessage.pack(reply))), on: connection)
                }
                receive(on: connection, channel: channel, secure: nextSecure)
            } catch { connection.cancel() }
        }
    }
}
