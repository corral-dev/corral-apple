import Foundation

/// 局域网开发机发现：只生产"候选地址"，不参与连接决策。
///
/// 解耦约定：发现机制（静态 hints / hello 刷新 / Bonjour）的唯一产出是
/// `[String]` 形式的 `"ip:port"` 数组；抢答逻辑只消费这份数组，
/// 不感知它来自哪一种发现手段。调用见 `AppModel.connect(to:)`（冷启动）。
///
/// nonisolated、可测、不依赖 `RemoteClient`。失败或超时一律返回 `[]`，
/// 绝不抛出，调用方直接降级走静态 hints + 中继抢答。
nonisolated struct DiscoveredHost: Sendable, Equatable {
    /// 完整 host_id（与 TXT `hid` 比对）。
    let hostID: String
    let name: String
    /// 去重后的 `"ip:port"` 字符串。
    let addresses: [String]
    let port: Int
}

/// Bonjour/mDNS 发现（`_corral._tcp.local.`）。
///
/// 开发机广播 service 名 `Corral-<host_id前8字符>`，TXT 携带
/// `hid=<完整host_id>` 与 `v=2`。同网多开发机共存时只按 `hid` 匹配目标，
/// 无 hid 或对不上的广播直接忽略。
///
/// 实现选 `NetServiceBrowser` + `NetService.resolve`（delegate 模式，
/// resolve 成熟、代码少），在内部包一层 async/await，对外只暴露
/// `browse(hostID:timeout:)`。
final class LanDiscovery: NSObject, @unchecked Sendable {
    /// Bonjour service 类型（`NWBrowser.Descriptor.bonjour(type:domain:)` 语义下的 type 部分）。
    nonisolated static let serviceType = "_corral._tcp."
    nonisolated static let serviceDomain = "local."
    nonisolated static let serviceNamePrefix = "Corral-"
    /// 单个 service 的 resolve 超时（秒）。
    nonisolated static let resolveTimeout: TimeInterval = 3.0

    nonisolated override init() {
        super.init()
    }

    /// 浏览局域网并返回目标开发机的 `"ip:port"` 候选（去重、排序）。
    /// 找不到、超时或无权限都返回 `[]`，绝不抛出。
    nonisolated func browse(hostID: String, timeout: TimeInterval = 2.0) async -> [String] {
        let target = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, timeout > 0 else { return [] }
        return await LanDiscoveryRunner.browse(hostID: target, timeout: timeout)
    }

    // MARK: - 纯函数（可单测）

    /// 由目标 hostID 拼出期待的 service 名前缀匹配：`Corral-<前8字符>`。
    nonisolated static func expectedServiceNamePrefix(hostID: String) -> String {
        serviceNamePrefix + hostID.prefix(8)
    }

    /// TXT 记录是否指向目标开发机（key 大小写不敏感，无 hid 则拒绝）。
    nonisolated static func txtMatchesHost(_ txt: [String: Data], hostID: String) -> Bool {
        for (key, value) in txt {
            guard key.lowercased() == "hid" else { continue }
            guard let hid = String(data: value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !hid.isEmpty
            else { return false }
            return hid == hostID
        }
        return false
    }

    /// 从一条 sockaddr 原始数据中提取 IPv4 字符串；非 IPv4 返回 nil。
    nonisolated static func ipv4String(fromAddressData data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            guard family == sa_family_t(AF_INET) else { return nil }
            var addr = in_addr()
            memcpy(&addr, base.advanced(by: 4), 4)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// 组装 `"ip:port"` 并去重排序；port 非法时返回空数组。
    nonisolated static func candidateStrings(addresses: [Data], port: Int) -> [String] {
        guard port > 0, port <= 65535 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for raw in addresses {
            guard let ip = ipv4String(fromAddressData: raw) else { continue }
            let candidate = "\(ip):\(port)"
            guard seen.insert(candidate).inserted else { continue }
            result.append(candidate)
        }
        return result.sorted()
    }
}

// MARK: - 浏览会话（主线程 delegate，内部使用）

/// 一次 `browse` 调用的完整生命周期：搜索 → resolve → 汇总。
/// 全部状态收敛在主隔离域，delegate 回调与超时都在同一串行上下文完成。
///
/// `NetServiceBrowser` 对 delegate 是弱引用，必须用 `active` 表把 runner
/// 强留到 `finish`，否则超时 Task 的 `[weak self]` 会变成 nil，continuation
/// 永不 resume（单测表现为 SWIFT TASK CONTINUATION MISUSE 挂死）。
@MainActor
private final class LanDiscoveryRunner: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private static var active: [ObjectIdentifier: LanDiscoveryRunner] = [:]

    private let hostID: String
    private let timeout: TimeInterval
    private var browser: NetServiceBrowser?
    private var pendingServices: [NetService] = []
    private var found: Set<String> = []
    private var continuation: CheckedContinuation<[String], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    private init(hostID: String, timeout: TimeInterval) {
        self.hostID = hostID
        // 封顶 10 秒：browse 是冷启动的前置步骤，不能无限拖住抢答。
        self.timeout = min(max(timeout, 0.1), 10)
        super.init()
    }

    static func browse(hostID: String, timeout: TimeInterval) async -> [String] {
        // Must start synchronously on MainActor before suspending: a nested
        // `Task { @MainActor }` behind an already-waiting MainActor caller can
        // leave the continuation parked forever (UI stuck on Connecting).
        let runner = LanDiscoveryRunner(hostID: hostID, timeout: timeout)
        return await withCheckedContinuation { continuation in
            runner.continuation = continuation
            active[ObjectIdentifier(runner)] = runner
            runner.start()
        }
    }

    private func start() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(
            ofType: LanDiscovery.serviceType,
            inDomain: LanDiscovery.serviceDomain
        )
        let seconds = timeout
        // Strong capture: missing finish() hangs every caller on Connecting.
        timeoutTask = Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in pendingServices {
            service.stop()
            service.delegate = nil
        }
        pendingServices.removeAll()
        let result = found.sorted()
        let cont = continuation
        continuation = nil
        Self.active[ObjectIdentifier(self)] = nil
        cont?.resume(returning: result)
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard !finished else { return }
        // 同网多开发机共存：service 名先粗筛，最终以 TXT hid 为准。
        guard service.name.hasPrefix(LanDiscovery.serviceNamePrefix) else { return }
        service.delegate = self
        pendingServices.append(service)
        service.resolve(withTimeout: LanDiscovery.resolveTimeout)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        // 无局域网权限 / mDNS 不可用：直接降级为空候选，不抛错。
        finish()
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !finished else { return }
        pendingServices.removeAll { $0 === sender }
        sender.delegate = nil
        let txt = NetService.dictionary(fromTXTRecord: sender.txtRecordData() ?? Data())
        guard LanDiscovery.txtMatchesHost(txt, hostID: hostID) else { return }
        let addresses = sender.addresses ?? []
        for candidate in LanDiscovery.candidateStrings(addresses: addresses, port: sender.port) {
            found.insert(candidate)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard !finished else { return }
        pendingServices.removeAll { $0 === sender }
        sender.delegate = nil
    }
}
