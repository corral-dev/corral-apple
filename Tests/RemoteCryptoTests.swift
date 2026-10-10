import Foundation
@testable import Corral
import XCTest

final class RemoteCryptoTests: XCTestCase {
    // MARK: - HKDF 固定向量（与 Python `_hkdf` 对齐）

    func testHKDFKnownVector() {
        let ikm = Data("input key material".utf8)
        let salt = Data("salt".utf8)
        let info = Data("corral/remote/v2 d2h".utf8)
        let derived = RemoteHKDF.derive(ikm: ikm, salt: salt, info: info, length: 32)
        XCTAssertEqual(derived.count, 32)
        // 与 Python 同输入跑出的 digest，防止 HKDF 实现漂移
        XCTAssertEqual(derived.hexString, "50c9e9a6f14b31a9f33df8b0de70e6b18bb83a13f3439b336bb34b1f5cb8abc7")
    }

    // MARK: - 通道加解密 round-trip

    func testSecureChannelRoundTrip() throws {
        let sendKey = Data(repeating: 0x01, count: 32)
        let recvKey = Data(repeating: 0x02, count: 32)
        let peer = Data(repeating: 0xAB, count: 32)

        let alice = SecureChannel(sendKey: sendKey, recvKey: recvKey, peerStaticPublic: peer)
        let bob = SecureChannel(sendKey: recvKey, recvKey: sendKey, peerStaticPublic: peer)

        let plaintext = Data("你好，corral".utf8)
        let frame = try alice.encrypt(plaintext)
        XCTAssertGreaterThanOrEqual(frame.count, 8 + 16)
        XCTAssertEqual(frame.prefix(8), Data([0, 0, 0, 0, 0, 0, 0, 0]))

        let decrypted = try bob.decrypt(frame)
        XCTAssertEqual(decrypted, plaintext)

        let reply = Data("pong".utf8)
        let replyFrame = try bob.encrypt(reply)
        let opened = try alice.decrypt(replyFrame)
        XCTAssertEqual(opened, reply)
    }

    func testSecureChannelRejectsOutOfOrderCounter() throws {
        let key = Data(repeating: 0x03, count: 32)
        let peer = Data(repeating: 0xCD, count: 32)
        let channel = SecureChannel(sendKey: key, recvKey: key, peerStaticPublic: peer)

        let frame0 = try channel.encrypt(Data("a".utf8))
        _ = try channel.decrypt(frame0)

        XCTAssertThrowsError(try channel.decrypt(frame0)) { error in
            guard case RemoteCryptoError.channel(let message) = error else {
                return XCTFail("期待 channel 错误")
            }
            XCTAssertEqual(message, "加密帧顺序异常")
        }
    }

    // MARK: - 设备握手

    func testDeviceHandshakeProducesDistinctDirectionalKeys() throws {
        let deviceStatic = RemoteCryptoKeys.generatePrivateKey()
        let hostStatic = RemoteCryptoKeys.generatePrivateKey()

        let deviceHS = try DeviceHandshake(staticPrivate: deviceStatic)
        let hostEphemeralPrivate = RemoteCryptoKeys.generatePrivateKey()
        let hostEphemeral = try RemoteCryptoKeys.publicKey(from: hostEphemeralPrivate)

        let deviceChannel = try deviceHS.complete(hostStatic: try RemoteCryptoKeys.publicKey(from: hostStatic), hostEphemeral: hostEphemeral)

        // 模拟开发机侧 derive（as_host=true）
        let hostChannel = try deriveHostChannel(
            hostStaticPrivate: hostStatic,
            hostEphemeralPrivate: hostEphemeralPrivate,
            deviceStatic: deviceHS.staticPublic,
            deviceEphemeral: deviceHS.ephemeralPublic
        )

        let msg = Data("handshake ok".utf8)
        let wire = try deviceChannel.encrypt(msg)
        let plain = try hostChannel.decrypt(wire)
        XCTAssertEqual(plain, msg)
    }

    // MARK: - 推送解封

    func testPushSealRoundTrip() throws {
        let hostStatic = RemoteCryptoKeys.generatePrivateKey()
        let deviceStatic = RemoteCryptoKeys.generatePrivateKey()
        let hostPublic = try RemoteCryptoKeys.publicKey(from: hostStatic)
        let devicePublic = try RemoteCryptoKeys.publicKey(from: deviceStatic)

        let plaintext = Data("{\"title\":\"会话\"}".utf8)
        let sealed = try RemotePushCrypto.sealForDevice(
            hostStaticPrivate: hostStatic,
            devicePublic: devicePublic,
            plaintext: plaintext
        )
        let opened = try RemotePushCrypto.openFromHost(
            deviceStaticPrivate: deviceStatic,
            hostPublic: hostPublic,
            sealed: sealed
        )
        XCTAssertEqual(opened, plaintext)
    }

    // MARK: - 帧协议

    func testWireFrameRoundTrip() throws {
        let channel = Data(repeating: 0x42, count: WireProtocol.channelIDLength)
        let payload = Data("payload".utf8)
        let encoded = try WireFrame.encode(type: WireProtocol.frameData, channelID: channel, payload: payload)
        XCTAssertEqual(encoded[0], WireProtocol.frameVersion)
        let decoded = try WireFrame.decode(encoded)
        XCTAssertEqual(decoded.type, WireProtocol.frameData)
        XCTAssertEqual(decoded.channelID, channel)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testWireMessageRequestShape() throws {
        let req = WireMessage.request(id: 7, method: "session.get", params: ["key": "abc"])
        let data = try WireMessage.dumps(req)
        let loaded = try WireMessage.loads(data)
        XCTAssertEqual(loaded["t"] as? String, "req")
        XCTAssertEqual(loaded["id"] as? Int, 7)
        XCTAssertEqual(loaded["m"] as? String, "session.get")
    }

    // MARK: - 配对链接

    func testPairingURLParse() throws {
        let key = Data(repeating: 0x11, count: 32)
        let keyB64 = PairingPayload.encodePublicKeyBase64URL(key)
        let url = "corral://pair?v=2&n=MacBook&k=\(keyB64)&c=ABCD1234&r=wss://relay.example.com&l=192.168.1.5:8737"
        let payload = try PairingPayload.parse(string: url)
        let expectedID = try RemoteCryptoKeys.routingID(fromX25519: key)
        XCTAssertEqual(payload.hostID, expectedID)
        XCTAssertEqual(payload.version, "2")
        XCTAssertEqual(payload.hostName, "MacBook")
        XCTAssertEqual(payload.pairingCode, "ABCD1234")
        XCTAssertEqual(payload.relayURL, "wss://relay.example.com")
        XCTAssertEqual(payload.localHints, ["192.168.1.5:8737"])
        XCTAssertEqual(payload.hostPublicKey, key)
    }

    func testPairingURLRejectsV1() {
        let key = Data(repeating: 0x11, count: 32)
        let keyB64 = PairingPayload.encodePublicKeyBase64URL(key)
        let url = "corral://pair?v=1&h=host123&n=MacBook&k=\(keyB64)&c=ABCD1234"
        XCTAssertThrowsError(try PairingPayload.parse(string: url)) { error in
            guard case PairingParseError.unsupportedVersion = error else {
                return XCTFail("期待旧版本提示")
            }
        }
    }

    func testRoutingIDMatchesPythonVector() throws {
        var pub = Data()
        for i in 0..<32 { pub.append(UInt8(i)) }
        XCTAssertEqual(try RemoteCryptoKeys.routingID(fromX25519: pub), "xp47bhr5gnbtbbmjviugjxbnxm")
    }

    func testPairingCodeEqualIgnoresSeparators() {
        XCTAssertTrue(PairingCode.codesEqual("abcd-1234", "ABCD 1234"))
        XCTAssertFalse(PairingCode.codesEqual("", "ABCD"))
    }

    // MARK: - 终端绘制裁剪

    @MainActor
    func testTerminalCellSkipsDefaultBlankDrawing() {
        let blank = TerminalCell()
        XCTAssertFalse(blank.needsBackgroundFill)
        XCTAssertFalse(blank.needsGlyphDraw)

        var styledBlank = TerminalCell()
        styledBlank.bg = TerminalColor(raw: 4)
        XCTAssertTrue(styledBlank.needsBackgroundFill)
        XCTAssertFalse(styledBlank.needsGlyphDraw)

        var character = TerminalCell(char: "你")
        character.reverse = true
        XCTAssertTrue(character.needsBackgroundFill)
        XCTAssertTrue(character.needsGlyphDraw)
    }

    // MARK: - 连接候选（抢答）

    @MainActor
    func testConnectCandidatesIncludesAllLocalHintsAndRelay() {
        let host = HostInfo(
            hostID: "abc",
            name: "suzhou",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: "wss://relay.example.com",
            localHints: ["192.168.1.5:8737", "10.0.0.2:8737"]
        )
        let all = host.connectCandidates(includeLocal: true)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].transport, .local)
        XCTAssertEqual(all[0].timeout, 2)
        XCTAssertEqual(all[1].transport, .local)
        XCTAssertEqual(all[2].transport, .relay)
        XCTAssertEqual(all[2].timeout, 8)
        XCTAssertTrue(all[2].url?.absoluteString.contains("/v2/device?host=abc") == true)

        let relayOnly = host.connectCandidates(includeLocal: false)
        XCTAssertEqual(relayOnly.count, 1)
        XCTAssertEqual(relayOnly[0].transport, .relay)
    }

    @MainActor
    func testLongLivedWebSocketSessionDoesNotUseHandshakeTimeout() {
        let local = ConnectCandidate(kind: .direct(URL(string: "ws://127.0.0.1:8737")!))
        let relay = ConnectCandidate(
            kind: .relay(baseURL: URL(string: "wss://relay.example.com")!, hostID: "abc")
        )
        XCTAssertEqual(local.timeout, 2)
        XCTAssertEqual(relay.timeout, 8)

        let config = RemoteWebSocketSession.makeConfiguration()
        XCTAssertGreaterThan(config.timeoutIntervalForResource, 8)
        XCTAssertGreaterThan(config.timeoutIntervalForRequest, 8)
        XCTAssertNotEqual(config.timeoutIntervalForResource, local.timeout)
        XCTAssertNotEqual(config.timeoutIntervalForResource, relay.timeout)
        XCTAssertNotEqual(config.timeoutIntervalForRequest, local.timeout)
        XCTAssertNotEqual(config.timeoutIntervalForRequest, relay.timeout)
        XCTAssertTrue(
            config.timeoutIntervalForResource.isInfinite
                || config.timeoutIntervalForResource >= 3600
        )
        XCTAssertGreaterThanOrEqual(
            config.timeoutIntervalForRequest,
            RemoteWebSocketSession.requestTimeout
        )
        XCTAssertFalse(config.waitsForConnectivity)
    }

    @MainActor
    func testConnectCandidatesDoesNotInventSharedRelay() {
        let host = HostInfo(
            hostID: "xyz",
            name: "mac",
            publicKeyHex: String(repeating: "cd", count: 32),
            relayURL: nil,
            localHints: ["192.168.0.2:8737"]
        )
        let candidates = host.connectCandidates(includeLocal: true)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].transport, .local)

        let withExplicitDefault = host.connectCandidates(
            includeLocal: true,
            defaultRelay: "wss://relay.example.com"
        )
        XCTAssertEqual(withExplicitDefault.count, 2)
        XCTAssertEqual(withExplicitDefault[1].transport, .relay)
        XCTAssertTrue(
            withExplicitDefault[1].url?.absoluteString.contains("relay.example.com") == true
        )
    }

    // MARK: - 开发机侧 derive（仅测试用，镜像 Python Handshake.accept）

    private func deriveHostChannel(
        hostStaticPrivate: Data,
        hostEphemeralPrivate: Data,
        deviceStatic: Data,
        deviceEphemeral: Data
    ) throws -> SecureChannel {
        let hostEphemeral = try RemoteCryptoKeys.publicKey(from: hostEphemeralPrivate)

        let ikm =
            try RemoteCryptoKeys.diffieHellman(privateKey: hostEphemeralPrivate, peerPublic: deviceEphemeral)
            + RemoteCryptoKeys.diffieHellman(privateKey: hostStaticPrivate, peerPublic: deviceStatic)
            + RemoteCryptoKeys.diffieHellman(privateKey: hostStaticPrivate, peerPublic: deviceEphemeral)
            + RemoteCryptoKeys.diffieHellman(privateKey: hostEphemeralPrivate, peerPublic: deviceStatic)

        let salt = deviceEphemeral + hostEphemeral
        let d2h = RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoD2H)
        let h2d = RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoH2D)
        return SecureChannel(sendKey: h2d, recvKey: d2h, peerStaticPublic: deviceStatic)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
