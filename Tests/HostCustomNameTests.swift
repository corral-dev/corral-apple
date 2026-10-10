import Foundation
@testable import Corral
import XCTest

/// 开发机本地别名：customName 只存本机 paired-hosts.json，不上服务端；
/// 显示走 displayName（别名优先，否则默认名）；hello 默认名只更新 name。
@MainActor
final class HostCustomNameTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-hosts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        HostStore.directoryOverride = scratch
        HostStore.shared.replaceAllForTesting([])
    }

    override func tearDown() async throws {
        HostStore.shared.replaceAllForTesting([])
        HostStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private func payload(hostName: String = "dev") -> PairingPayload {
        PairingPayload(
            version: "2",
            hostID: "host-1",
            hostName: hostName,
            hostPublicKey: Data(repeating: 7, count: 32),
            pairingCode: "code",
            relayURL: nil,
            localHints: []
        )
    }

    func testDisplayNameFallsBackToServerName() {
        let host = HostInfo(from: payload())
        XCTAssertNil(host.customName)
        XCTAssertEqual(host.displayName, "dev")
    }

    func testCustomNameWinsOverServerName() {
        var host = HostInfo(from: payload())
        host.customName = "MacBook-Max"
        XCTAssertEqual(host.displayName, "MacBook-Max")
    }

    func testBlankCustomNameFallsBack() {
        var host = HostInfo(from: payload())
        host.customName = "   "
        XCTAssertEqual(host.displayName, "dev")
    }

    func testSetCustomNameTrimsAndClearsOnBlank() {
        HostStore.shared.upsertHost(HostInfo(from: payload()))
        HostStore.shared.setCustomName(hostID: "host-1", name: "  MacBook-Max  ")
        XCTAssertEqual(HostStore.shared.host(for: "host-1")?.displayName, "MacBook-Max")
        HostStore.shared.setCustomName(hostID: "host-1", name: "   ")
        let stored = HostStore.shared.host(for: "host-1")
        XCTAssertNil(stored?.customName)
        XCTAssertEqual(stored?.displayName, "dev")
    }

    func testHelloNameUpdatesDefaultButKeepsAlias() {
        HostStore.shared.upsertHost(HostInfo(from: payload()))
        HostStore.shared.setCustomName(hostID: "host-1", name: "我的机器")
        HostStore.shared.applyHelloHostName(hostID: "host-1", name: "MacBook-Max")
        let stored = HostStore.shared.host(for: "host-1")
        XCTAssertEqual(stored?.name, "MacBook-Max")
        XCTAssertEqual(stored?.displayName, "我的机器")
    }

    func testHelloNameUpdatesDisplayWhenNoAlias() {
        HostStore.shared.upsertHost(HostInfo(from: payload()))
        HostStore.shared.applyHelloHostName(hostID: "host-1", name: "MacBook-Max")
        XCTAssertEqual(HostStore.shared.host(for: "host-1")?.displayName, "MacBook-Max")
    }

    func testRepairingKeepsLocalAlias() {
        HostStore.shared.upsertHost(HostInfo(from: payload()))
        HostStore.shared.setCustomName(hostID: "host-1", name: "我的机器")
        // 服务端 rename 后重扫：默认名变了，本地别名必须保留。
        HostStore.shared.addFromPairing(payload(hostName: "MacBook-Max"))
        let stored = HostStore.shared.host(for: "host-1")
        XCTAssertEqual(stored?.name, "MacBook-Max")
        XCTAssertEqual(stored?.displayName, "我的机器")
    }

    func testCustomNameSurvivesEncodeDecode() throws {
        var host = HostInfo(from: payload())
        host.customName = "我的机器"
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(HostInfo.self, from: data)
        XCTAssertEqual(decoded.customName, "我的机器")
        XCTAssertEqual(decoded.displayName, "我的机器")
    }

    func testOldCacheWithoutCustomNameStillDecodes() throws {
        let json = """
        {"hostID":"host-1","name":"dev","publicKeyHex":"\(String(repeating: "07", count: 32))","localHints":[],"pairedAt":"2026-09-13T00:00:00Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HostInfo.self, from: json)
        XCTAssertNil(decoded.customName)
        XCTAssertEqual(decoded.displayName, "dev")
    }
}
