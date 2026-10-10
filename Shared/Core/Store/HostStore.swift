import Foundation
import Observation
import Security

/// 设备身份与已配对开发机持久化。
///
/// 长期私钥放 Keychain（32 字节 X25519），因为丢了这个就要重新配对；
/// 已配对开发机列表放 Application Support JSON，方便备份与调试。
@MainActor
@Observable
final class HostStore {
    static let shared = HostStore()
    /// 测试用覆盖目录：为 nil 时走 Application Support 真实路径。
    static var directoryOverride: URL?

    private(set) var hosts: [HostInfo] = []

    private let hostsFileName = "paired-hosts.json"

    private init() {
        loadHosts()
    }

    // MARK: - 设备身份

    /// 读取或生成设备长期私钥。配对绑的是公钥，换一把就要重新扫二维码。
    func loadOrCreateDevicePrivateKey() throws -> Data {
        if let existing = try readKeychainPrivateKey() {
            return existing
        }
        let key = RemoteCryptoKeys.generatePrivateKey()
        try saveKeychainPrivateKey(key)
        return key
    }

    func devicePublicKeyHex() throws -> String {
        let privateKey = try loadOrCreateDevicePrivateKey()
        let publicKey = try RemoteCryptoKeys.publicKey(from: privateKey)
        return publicKey.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 已配对开发机

    func host(for hostID: String) -> HostInfo? {
        hosts.first { $0.hostID == hostID }
    }

    func upsertHost(_ host: HostInfo) {
        if let index = hosts.firstIndex(where: { $0.hostID == host.hostID }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        if let keyData = host.publicKeyData {
            try? HostKeychain.saveHostPublicKey(hostID: host.hostID, publicKey: keyData)
        }
        saveHosts()
    }

    func removeHost(hostID: String) {
        hosts.removeAll { $0.hostID == hostID }
        HostKeychain.removeHostPublicKey(hostID: hostID)
        ConversationTailCache.removeAll(hostID: hostID)
        PendingCommandStore.removeAll(hostID: hostID)
        try? PendingSessionCreationStore.removeAll(hostID: hostID)
        SessionListCache.removeAll(hostID: hostID)
        ComposerDraftStore.removeAll(hostID: hostID)
        RecentSessionComboStore.removeAll(hostID: hostID)
        saveHosts()
    }

    /// 测试夹具：把内存与落盘一起换成给定列表（只用于单测隔离）。
    func replaceAllForTesting(_ hosts: [HostInfo]) {
        self.hosts = hosts
        saveHosts()
    }

    func addFromPairing(_ payload: PairingPayload) {
        // 重扫已配对机器不得丢掉本地别名：先取旧别名再覆盖。
        let existing = host(for: payload.hostID)
        var fresh = HostInfo(from: payload)
        fresh.customName = existing?.customName
        upsertHost(fresh)
    }

    /// 设置/清除本机自定义别名。空串表示清除，回到开发机下发的默认名。
    /// 别名只存本机，不发给服务端；其它手机不受影响。
    func setCustomName(hostID: String, name: String?) {
        guard var stored = host(for: hostID) else { return }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        guard stored.customName != next else { return }
        stored.customName = next
        upsertHost(stored)
    }

    /// hello 带回开发机默认名：只在用户没设本地别名时跟随，避免覆盖用户改名。
    func applyHelloHostName(hostID: String, name: String?) {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              var stored = host(for: hostID)
        else { return }
        let next = String(raw.prefix(80))
        guard stored.name != next else { return }
        // 已设本地别名的机器：默认名照样更新，但显示仍用别名。
        stored.name = next
        upsertHost(stored)
    }

    /// Replace stored LAN hints with a fresh hello/bonjour snapshot.
    func updateLocalHints(hostID: String, hints: [String]) {
        guard var stored = host(for: hostID) else { return }
        let updated = stored.applyingFreshLocalHints(hints)
        guard updated.localHints != stored.localHints else { return }
        stored = updated
        upsertHost(stored)
    }

    /// Remember which LAN endpoint just won — next cold start tries it first.
    func rememberLastLocalHint(hostID: String, hint: String) {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var stored = host(for: hostID) else { return }
        if stored.lastLocalHint == trimmed { return }
        stored.lastLocalHint = trimmed
        if !stored.localHints.contains(trimmed) {
            stored.localHints = ([trimmed] + stored.localHints)
            if stored.localHints.count > 12 {
                stored.localHints = Array(stored.localHints.prefix(12))
            }
        }
        upsertHost(stored)
    }

    // MARK: - Keychain

    private func readKeychainPrivateKey() throws -> Data? {
        try HostKeychain.readDevicePrivateKey()
    }

    private func saveKeychainPrivateKey(_ key: Data) throws {
        guard key.count == 32 else { throw HostKeychainError.invalidKeyLength }
        try HostKeychain.saveDevicePrivateKey(key)
    }

    // MARK: - JSON 持久化

    private var hostsFileURL: URL {
        if let override = Self.directoryOverride {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override.appendingPathComponent(hostsFileName)
        }
        let dir = AppStorageLocation.appDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(hostsFileName)
    }

    private func loadHosts() {
        guard let data = try? Data(contentsOf: hostsFileURL) else {
            hosts = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        hosts = (try? decoder.decode([HostInfo].self, from: data)) ?? []
    }

    private func saveHosts() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: hostsFileURL, options: .atomic)
    }
}

/// 连接走的通路：局域网直连或公网中继。
nonisolated enum ConnectionTransport: String, Sendable, Equatable {
    case local
    case relay
}

/// 一条可尝试的连接候选（抢答用）。
nonisolated struct ConnectCandidate: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case direct(URL)
        case relay(baseURL: URL, hostID: String)
    }

    let kind: Kind

    var transport: ConnectionTransport {
        switch kind {
        case .direct: .local
        case .relay: .relay
        }
    }

    /// 局域网不可达时必须尽快失败，绝不能堵死中继抢答。
    /// 同网直连通常几十毫秒；给 2 秒是为了第一次系统本地网络权限/路由，死地址也让路。
    var timeout: TimeInterval {
        switch transport {
        case .local: 2
        case .relay: 8
        }
    }

    var url: URL? {
        switch kind {
        case let .direct(url):
            return url
        case let .relay(baseURL, hostID):
            let base = baseURL.absoluteString.hasSuffix("/")
                ? String(baseURL.absoluteString.dropLast())
                : baseURL.absoluteString
            var components = URLComponents(string: "\(base)/v2/device")
            components?.queryItems = [URLQueryItem(name: "host", value: hostID)]
            return components?.url
        }
    }
}

extension HostInfo {
    /// 构造 WebSocket 连接地址：优先局域网提示，否则走中继。
    func webSocketURL(preferLocal: Bool = true) -> URL? {
        connectCandidates(includeLocal: preferLocal).first?.url
    }

    /// All candidate addresses for a race.
    ///
    /// Order (fast LAN path): last successful local → fresh static/bonjour
    /// hints (capped) → relay. Dead DHCP leftovers must not pile up; Bonjour
    /// is optional and never blocks the race by itself.
    func connectCandidates(
        includeLocal: Bool = true,
        defaultRelay: String = "",
        bonjourHints: [String] = [],
        round: Int = 0
    ) -> [ConnectCandidate] {
        var result: [ConnectCandidate] = []
        var seen: Set<String> = []

        func append(_ candidate: ConnectCandidate) {
            guard let url = candidate.url else { return }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return }
            result.append(candidate)
        }

        func appendDirect(from raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let url: URL?
            if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
                url = URL(string: trimmed)
            } else {
                url = URL(string: "ws://\(trimmed)")
            }
            if let url {
                append(ConnectCandidate(kind: .direct(url)))
            }
        }

        if includeLocal {
            // A host on this very machine is always reachable over loopback, which
            // survives Wi-Fi address changes, VPN churn and interface sleep.
            if let loopback = SameMachineHost.loopbackHint(for: localHints + [lastLocalHint].compactMap { $0 }) {
                appendDirect(from: loopback)
            }
            let loopbacks = result
            result = []
            seen = []
            if let last = lastLocalHint { appendDirect(from: last) }
            for hint in localHints + bonjourHints { appendDirect(from: hint) }
            let all = result.filter { candidate in
                !loopbacks.contains { $0.url == candidate.url }
            }
            let start = all.isEmpty ? 0 : (max(round, 0) % all.count) * min(3, all.count) % all.count
            let window = (0..<min(3, all.count)).map { all[(start + $0) % all.count] }
            result = loopbacks + window
            seen = Set(result.compactMap { $0.url?.absoluteString })
        }

        var relayStrings: [String] = []
        if let relayURL, !relayURL.isEmpty {
            relayStrings.append(relayURL)
        }
        if !defaultRelay.isEmpty {
            relayStrings.append(defaultRelay)
        }
        for relay in relayStrings {
            guard let base = URL(string: relay) else { continue }
            append(ConnectCandidate(kind: .relay(baseURL: base, hostID: hostID)))
        }
        return result
    }
}

/// Detects a paired host that runs on this machine (Mac client + local `corral remote`).
nonisolated enum SameMachineHost {
    /// `127.0.0.1:<port>` when one of `hints` is an address of this machine.
    static func loopbackHint(for hints: [String], ownAddresses: Set<String> = interfaceAddresses()) -> String? {
        guard !ownAddresses.isEmpty else { return nil }
        for hint in hints {
            guard let (host, port) = split(hint) else { continue }
            if host == "127.0.0.1" || host == "localhost" || ownAddresses.contains(host) {
                return "127.0.0.1:\(port)"
            }
        }
        return nil
    }

    /// `ip:port`, `ws://ip:port[/path]` → (ip, port). IPv6 hints are ignored.
    static func split(_ hint: String) -> (String, Int)? {
        var raw = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["ws://", "wss://"] where raw.hasPrefix(scheme) {
            raw.removeFirst(scheme.count)
        }
        if let slash = raw.firstIndex(of: "/") {
            raw = String(raw[..<slash])
        }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), port > 0 else { return nil }
        return (String(parts[0]), port)
    }

    /// IPv4 addresses of this machine's interfaces. Only the Mac can host Corral.
    static func interfaceAddresses() -> Set<String> {
        #if os(macOS)
        var result: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            )
            if status == 0 {
                result.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return result
        #else
        return []
        #endif
    }
}
