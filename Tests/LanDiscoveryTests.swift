import XCTest
@testable import Corral

/// 局域网发现 + 换网无感切换：候选生产与抢答消费的解耦契约。
@MainActor
final class LanDiscoveryTests: XCTestCase {
    // MARK: - HelloResponse local_hints 解析

    func testHelloParsesLocalHints() throws {
        let hello = try RemoteJSONDecoder.decode(
            HelloResponse.self,
            from: [
                "paired": true,
                "local_hints": ["192.168.1.5:8737", "10.0.0.3:8737"],
            ]
        )
        XCTAssertEqual(hello.localHints, ["192.168.1.5:8737", "10.0.0.3:8737"])
    }

    func testHelloWithoutLocalHintsIsNil() throws {
        let hello = try RemoteJSONDecoder.decode(
            HelloResponse.self,
            from: ["paired": true]
        )
        XCTAssertNil(hello.localHints)
    }

    func testHelloSkipsBadLocalHintElements() throws {
        let hello = try RemoteJSONDecoder.decode(
            HelloResponse.self,
            from: [
                "paired": true,
                "local_hints": ["192.168.1.5:8737", 42, NSNull(), "  ", "10.0.0.3:8737"],
            ]
        )
        XCTAssertEqual(hello.localHints, ["192.168.1.5:8737", "10.0.0.3:8737"])
    }

    func testHelloEmptyLocalHintsIsNil() throws {
        let hello = try RemoteJSONDecoder.decode(
            HelloResponse.self,
            from: [
                "paired": true,
                "local_hints": [] as [String],
            ]
        )
        XCTAssertNil(hello.localHints)
    }

    // MARK: - mergingLocalHints 去重合并

    func testMergingLocalHintsPutsFreshFirstAndCaps() {
        let host = HostInfo(
            hostID: "abc",
            name: "suzhou",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: nil,
            localHints: ["192.168.1.5:8737", "10.0.0.1:8737"]
        )
        let merged = host.mergingLocalHints(
            ["192.168.1.6:8737", "192.168.1.5:8737", "  "],
            cap: 3
        )
        // Fresh first; shared address not duplicated; oldest dropped by cap.
        XCTAssertEqual(
            merged.localHints,
            ["192.168.1.6:8737", "192.168.1.5:8737", "10.0.0.1:8737"]
        )
        // 原对象不变，Codable 字段未动。
        XCTAssertEqual(host.localHints, ["192.168.1.5:8737", "10.0.0.1:8737"])
        XCTAssertEqual(merged.hostID, host.hostID)
        XCTAssertEqual(merged.publicKeyHex, host.publicKeyHex)
    }

    // MARK: - connectCandidates 排序：静态 direct → bonjour → relay

    func testConnectCandidatesOrdersStaticThenBonjourThenRelay() {
        let host = HostInfo(
            hostID: "abc",
            name: "suzhou",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: "wss://relay.example.com",
            localHints: ["192.168.1.5:8737"]
        )
        let candidates = host.connectCandidates(
            includeLocal: true,
            bonjourHints: ["192.168.1.9:8737"]
        )
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].transport, .local)
        XCTAssertEqual(candidates[0].url?.absoluteString, "ws://192.168.1.5:8737")
        XCTAssertEqual(candidates[1].transport, .local)
        XCTAssertEqual(candidates[1].url?.absoluteString, "ws://192.168.1.9:8737")
        XCTAssertEqual(candidates[2].transport, .relay)
    }

    func testConnectCandidatesBonjourDedupesAgainstStatic() {
        let host = HostInfo(
            hostID: "abc",
            name: "suzhou",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: nil,
            localHints: ["192.168.1.5:8737"]
        )
        let candidates = host.connectCandidates(
            includeLocal: true,
            bonjourHints: ["192.168.1.5:8737", "192.168.1.9:8737"]
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].url?.absoluteString, "ws://192.168.1.5:8737")
        XCTAssertEqual(candidates[1].url?.absoluteString, "ws://192.168.1.9:8737")
    }

    func testConnectCandidatesBonjourIgnoredWhenLocalExcluded() {
        let host = HostInfo(
            hostID: "abc",
            name: "suzhou",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: "wss://relay.example.com",
            localHints: ["192.168.1.5:8737"]
        )
        let candidates = host.connectCandidates(
            includeLocal: false,
            bonjourHints: ["192.168.1.9:8737"]
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].transport, .relay)
    }

    func testConnectCandidatesDefaultBonjourIsEmpty() {
        let host = HostInfo(
            hostID: "abc",
            name: "suzhou",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: "wss://relay.example.com",
            localHints: ["192.168.1.5:8737"]
        )
        // 默认参数保持兼容：与老调用结果一致。
        XCTAssertEqual(
            host.connectCandidates(includeLocal: true).map(\.url?.absoluteString),
            host.connectCandidates(includeLocal: true, bonjourHints: []).map(\.url?.absoluteString)
        )
    }

    // MARK: - LanDiscovery 纯函数

    func testExpectedServiceNamePrefixUsesFirst8Chars() {
        XCTAssertEqual(
            LanDiscovery.expectedServiceNamePrefix(hostID: "abcdef123456"),
            "Corral-abcdef12"
        )
    }

    func testTxtMatchesHostRequiresHid() {
        let hostID = "abcdef1234567890"
        XCTAssertTrue(
            LanDiscovery.txtMatchesHost(["hid": Data(hostID.utf8)], hostID: hostID)
        )
        // Bonjour TXT key 大小写不敏感：HID 与 hid 等价。
        XCTAssertTrue(
            LanDiscovery.txtMatchesHost(["HID": Data(hostID.utf8)], hostID: hostID)
        )
        XCTAssertFalse(
            LanDiscovery.txtMatchesHost(["v": Data("2".utf8)], hostID: hostID)
        )
        XCTAssertFalse(
            LanDiscovery.txtMatchesHost(["hid": Data("other".utf8)], hostID: hostID)
        )
        XCTAssertFalse(
            LanDiscovery.txtMatchesHost(["hid": Data("  ".utf8)], hostID: hostID)
        )
        XCTAssertFalse(LanDiscovery.txtMatchesHost([:], hostID: hostID))
    }

    func testCandidateStringsDedupesAndSorts() {
        let v4a = sockaddrData(ipv4: (192, 168, 1, 9))
        let v4b = sockaddrData(ipv4: (192, 168, 1, 5))
        let result = LanDiscovery.candidateStrings(addresses: [v4a, v4b, v4a], port: 8737)
        XCTAssertEqual(result, ["192.168.1.5:8737", "192.168.1.9:8737"])
    }

    func testCandidateStringsRejectsBadPort() {
        let v4 = sockaddrData(ipv4: (192, 168, 1, 5))
        XCTAssertTrue(LanDiscovery.candidateStrings(addresses: [v4], port: 0).isEmpty)
        XCTAssertTrue(LanDiscovery.candidateStrings(addresses: [v4], port: 99999).isEmpty)
    }

    // MARK: - LanDiscovery 超时不抛

    func testBrowseUnknownHostTimesOutToEmpty() async {
        // 不存在的 hostID：2 秒内 browse 不到，直接返回 [] 而不是抛错/挂起。
        let result = await LanDiscovery().browse(
            hostID: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            timeout: 0.5
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBrowseEmptyHostIDReturnsEmptyImmediately() async {
        let result = await LanDiscovery().browse(hostID: "  ", timeout: 0.5)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - 探测决策纯逻辑

    func testPathReconnectGateIgnoresDuringConnecting() {
        XCTAssertFalse(
            PathReconnectGate.shouldHandlePathChange(
                connectionStateIsConnecting: true,
                suppressUntil: nil
            )
        )
        let future = Date().addingTimeInterval(5)
        XCTAssertFalse(
            PathReconnectGate.shouldHandlePathChange(
                connectionStateIsConnecting: false,
                suppressUntil: future
            )
        )
        let past = Date().addingTimeInterval(-1)
        XCTAssertTrue(
            PathReconnectGate.shouldHandlePathChange(
                connectionStateIsConnecting: false,
                suppressUntil: past
            )
        )
    }

    func testLocalCandidateTimeoutIsTwoSeconds() {
        let candidate = ConnectCandidate(kind: .direct(URL(string: "ws://192.168.1.5:8737")!))
        XCTAssertEqual(candidate.timeout, 2, accuracy: 0.001)
        let relay = ConnectCandidate(
            kind: .relay(baseURL: URL(string: "wss://relay.example.com")!, hostID: "abc")
        )
        XCTAssertEqual(relay.timeout, 8, accuracy: 0.001)
    }

    func testConnectAttemptGateIgnoresStaleAndReusesInFlight() {
        XCTAssertTrue(
            ConnectAttemptGate.shouldReuseInFlight(
                selectedHostID: "abc",
                targetHostID: "abc",
                connectionStateIsBusy: true,
                hasClient: true
            )
        )
        XCTAssertFalse(
            ConnectAttemptGate.shouldReuseInFlight(
                selectedHostID: "abc",
                targetHostID: "xyz",
                connectionStateIsBusy: true,
                hasClient: true
            )
        )
        XCTAssertFalse(
            ConnectAttemptGate.shouldReuseInFlight(
                selectedHostID: "abc",
                targetHostID: "abc",
                connectionStateIsBusy: false,
                hasClient: true
            )
        )
        XCTAssertTrue(ConnectAttemptGate.shouldApplyResult(attempt: 3, current: 3))
        XCTAssertFalse(ConnectAttemptGate.shouldApplyResult(attempt: 2, current: 3))
    }

    func testConnectCandidatesPutsLastLocalFirstButStillIncludesRelay() {
        let host = HostInfo(
            hostID: "abc",
            name: "suzhou",
            publicKeyHex: String(repeating: "ab", count: 32),
            relayURL: "wss://relay.example.com",
            localHints: ["192.168.1.5:8737", "10.0.0.3:8737"],
            lastLocalHint: "192.168.1.9:8737"
        )
        let candidates = host.connectCandidates(includeLocal: true)
        XCTAssertEqual(candidates.first?.url?.absoluteString, "ws://192.168.1.9:8737")
        XCTAssertTrue(candidates.contains { $0.transport == .relay })
        // Race starts all of these together — order only affects logging / fairness.
        XCTAssertLessThanOrEqual(candidates.filter { $0.transport == .local }.count, 3)
    }

    // MARK: - helpers

    /// 构造一条 IPv4 sockaddr 原始数据（与 `NetService.addresses` 同形状）。
    private func sockaddrData(ipv4: (UInt8, UInt8, UInt8, UInt8)) -> Data {
        var storage = sockaddr_in()
        storage.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        storage.sin_family = sa_family_t(AF_INET)
        storage.sin_port = in_port_t(8737).bigEndian
        storage.sin_addr.s_addr = in_addr_t(ipv4.0) << 24
            | in_addr_t(ipv4.1) << 16
            | in_addr_t(ipv4.2) << 8
            | in_addr_t(ipv4.3)
        storage.sin_addr.s_addr = storage.sin_addr.s_addr.bigEndian
        return withUnsafeBytes(of: &storage) { Data($0) }
    }
}
