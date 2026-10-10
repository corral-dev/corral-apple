import Foundation
import Network
import Observation

/// 全局应用状态：开发机列表、当前连接与远程客户端。
@MainActor
@Observable
final class AppModel {
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(String)
    }

    private(set) var hosts: [HostInfo] = []
    var selectedHostID: String?
    /// 当前这条连接真正对应的开发机。和「界面刚点中的那一台」分开记，切机时不能先改选中再拿它判断要不要换连接。
    private(set) var connectedHostID: String?

    /// 当前连接 hello 带回的配对权限（"readonly" 则隐藏复制/接力菜单；nil 按旧开发机 full 处理）。
    private(set) var connectedAccess: String?
    /// 当前连接 hello 带回的配对权限（"readonly" 隐藏复制/接力菜单；nil 按旧开发机 full 处理）。
    private(set) var connectionState: ConnectionState = .disconnected
    /// 当前连接通路（局域网 / 中继），未连上时为 nil。
    private(set) var activeTransport: ConnectionTransport?
    private(set) var client: RemoteClient?
    /// 开启时局域网与中继并发抢答；关闭时只走中继（写入 UserDefaults）。
    var preferDirectConnection: Bool {
        didSet {
            UserDefaults.standard.set(preferDirectConnection, forKey: "corral.preferDirect")
            client?.setIncludeLocal(preferDirectConnection)
        }
    }
    /// 会话对话内容字号档位（写入 UserDefaults）。
    var sessionTextSize: SessionTextSize {
        didSet { UserDefaults.standard.set(sessionTextSize.rawValue, forKey: SessionTextSize.storageKey) }
    }

    private let hostStore: HostStore
    private var stateWatchTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var deferredPathCheck = false
    /// 冷启动抢答期间忽略 path 回调，避免刚开跑就被强制重连掐死。
    private var suppressPathReconnectUntil: Date?
    /// 同一台开发机正在连时，后来的调用等这一轮结束，不要再开一条。
    private var inFlightHostID: String?

    init(hostStore: HostStore = .shared) {
        self.hostStore = hostStore
        hosts = hostStore.hosts
        if UserDefaults.standard.object(forKey: "corral.preferDirect") == nil {
            preferDirectConnection = true
        } else {
            preferDirectConnection = UserDefaults.standard.bool(forKey: "corral.preferDirect")
        }
        sessionTextSize = SessionTextSize.resolve(
            stored: UserDefaults.standard.string(forKey: SessionTextSize.storageKey)
        )
        startPathMonitor()
        ChatMarkdown.prewarm()
    }

    var selectedHost: HostInfo? {
        guard let selectedHostID else { return hosts.first }
        return hosts.first { $0.hostID == selectedHostID } ?? hosts.first
    }

    func refreshHosts() {
        hosts = hostStore.hosts
    }

    func selectHost(_ host: HostInfo) {
        selectedHostID = host.hostID
    }

    /// 是否已经连着这台开发机。切到另一台时必须重连，不能只改选中项后继续拉上一台的会话。
    func isConnected(to host: HostInfo) -> Bool {
        !HostConnectionDecision.needsReconnect(
            connectedHostID: connectedHostID,
            targetHostID: host.hostID,
            isReady: connectionState == .connected && client != nil
        )
    }

    /// 连接当前选中的开发机。
    func connectSelectedHost() async {
        guard let host = selectedHost else {
            connectionState = .failed(String(localized: String.LocalizationValue("error.no_host")))
            return
        }
        await connect(to: host)
    }

    func connect(to host: HostInfo) async {
        if isConnected(to: host), client?.isUsable == true { return }
        if client?.reconnectHost?.hostID == host.hostID, connectionState == .reconnecting {
            client?.reconnectNow()
            return
        }
        if inFlightHostID == host.hostID {
            while inFlightHostID == host.hostID {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
            return
        }
        inFlightHostID = host.hostID
        defer {
            if inFlightHostID == host.hostID {
                inFlightHostID = nil
            }
        }
        // Owned by the model, not the caller: a view's `.task` is cancelled when the
        // user opens a machine, and that cancellation used to abort the data-plane
        // attach halfway. Awaiting an unstructured task does not propagate it.
        let work = Task { await self.performConnect(to: host) }
        await work.value
    }

    private func performConnect(to host: HostInfo) async {
        disconnect(clearSelection: false)
        connectionState = .connecting
        activeTransport = nil
        selectedHostID = host.hostID
        suppressPathReconnectUntil = Date().addingTimeInterval(PathReconnectGate.suppressSeconds)

        let remote: RemoteClient
        do {
            remote = try RemoteClient(hostStore: hostStore)
        } catch {
            connectionState = .failed(error.localizedDescription)
            return
        }
        client = remote
        remote.lastHelloName = UIDeviceName.current
        // Application readiness requires authenticated hello; push registration is independent.
        beginWatchingClientState(remote, hostID: host.hostID)

        do {
            try await remote.connect(
                host: host,
                includeLocal: preferDirectConnection,
                bonjourHints: []
            )
            guard client === remote else { return }
            do {
                let hello = try await remote.hello(name: UIDeviceName.current)
                guard client === remote else { return }
                applyHelloRelayIfNeeded(hello, hostID: host.hostID)
                applyHelloLocalHintsIfNeeded(hello, hostID: host.hostID)
                applyHelloHostNameIfNeeded(hello, hostID: host.hostID)
                connectedAccess = hello.access
                connectedHostID = host.hostID
                connectionState = .connected
                activeTransport = remote.activeTransport
                suppressPathReconnectUntil = nil
                if deferredPathCheck { deferredPathCheck = false; handleSceneBecameActive() }
                if preferDirectConnection, remote.activeTransport == .relay {
                    Task { [weak remote, weak self] in
                        await remote?.tryUpgradeToLocalIfNeeded()
                        guard let self, let remote, self.client === remote else { return }
                        self.activeTransport = remote.activeTransport
                    }
                }
                await requestPushAuthorizationIfNeeded()
                guard client === remote, !Task.isCancelled else { return }
                await registerPushIfNeeded(client: remote)
            } catch is CancellationError {
                return
            } catch {
                remote.recoverConnection(after: error)
                syncConnectionPresentation()
                return
            }
        } catch is CancellationError {
            guard client === remote else { return }
            if remote.isUsable {
                connectionState = .connected
                connectedHostID = host.hostID
                activeTransport = remote.activeTransport
                return
            }
            if remote.state == .reconnecting || remote.state == .connecting {
                connectionState = .reconnecting
                return
            }
            failConnection(from: remote, message: String(localized: String.LocalizationValue("connection.failed")))
        } catch {
            guard client === remote else { return }
            if remote.isUsable {
                connectionState = .connected
                connectedHostID = host.hostID
                activeTransport = remote.activeTransport
                return
            }
            remote.recoverConnection(after: error)
            syncConnectionPresentation()
        }
    }

    private func failConnection(from remote: RemoteClient, message: String) {
        guard client === remote else { return }
        stateWatchTask?.cancel()
        stateWatchTask = nil
        remote.disconnect()
        client = nil
        activeTransport = nil
        connectedHostID = nil
        connectedAccess = nil
        connectionState = .failed(message)
    }

    func disconnect(clearSelection: Bool = true) {
        stateWatchTask?.cancel()
        stateWatchTask = nil
        client?.disconnect()
        client = nil
        activeTransport = nil
        connectedHostID = nil
        connectedAccess = nil
        connectionState = .disconnected
        if clearSelection {
            selectedHostID = nil
        }
    }

    /// 应用回到前台：已空闲则强制重选路，禁止因为状态仍是 ready 就跳过。
    /// 换网虚惊不闪断：先轻量探测，路还通就保持 connected，只有真断才重连。
    func handleSceneBecameActive() {
        // 首轮抢答进行中：不要再开一条 connect / force 重连，否则互相取消。
        if connectionState == .connecting {
            return
        }
        if let client {
            client.setIncludeLocal(preferDirectConnection)
            if client.state == .ready {
                Task { [weak self] in
                    _ = await client.probeAndMigrateIfNeeded()
                    guard let self, self.client === client, !Task.isCancelled else { return }
                    self.syncConnectionPresentation()
                }
                return
            }
            client.reconnectNow()
        }
        syncConnectionPresentation()
        if client == nil, let host = selectedHost {
            Task { await connect(to: host) }
        }
    }

    /// 完成配对：连接 → pair → 持久化开发机。
    func completePairing(_ payload: PairingPayload, deviceName: String) async throws -> HostInfo {
        disconnect(clearSelection: false)
        connectionState = .connecting
        activeTransport = nil

        let remote = try RemoteClient(hostStore: hostStore)
        client = remote

        // 与日常连接同一套抢答：局域网候选与中继并发，禁止串行死等。
        // 本地别名由 HostStore 持有：抢答用的 HostInfo 只需路由身份，显示走 displayName。
        var host = HostInfo(from: payload)
        if !preferDirectConnection {
            host = HostInfo(
                hostID: host.hostID,
                name: host.name,
                publicKeyHex: host.publicKeyHex,
                relayURL: host.relayURL,
                localHints: [],
                pairedAt: host.pairedAt
            )
        }
        do {
            try await remote.connect(host: host, includeLocal: preferDirectConnection)
            try Task.checkCancellation()
            guard client === remote else { throw CancellationError() }
            _ = try await remote.pair(code: payload.pairingCode, name: deviceName, platform: UIDeviceName.pairingPlatform)
            try Task.checkCancellation()
            guard client === remote else { throw CancellationError() }
        } catch {
            failConnection(from: remote, message: error.localizedDescription)
            throw error
        }
        hostStore.addFromPairing(payload)
        refreshHosts()
        // If the QR omitted r=, hello may still carry the host's configured relay.
        do {
            let hello = try await remote.hello(name: deviceName)
            try Task.checkCancellation()
            guard client === remote else { throw CancellationError() }
            connectedAccess = hello.access
            applyHelloRelayIfNeeded(hello, hostID: payload.hostID)
            applyHelloLocalHintsIfNeeded(hello, hostID: payload.hostID)
            applyHelloHostNameIfNeeded(hello, hostID: payload.hostID)
        } catch {
            guard client === remote else { throw CancellationError() }
            remote.recoverConnection(after: error)
            syncConnectionPresentation()
            beginWatchingClientState(remote, hostID: payload.hostID)
            throw error
        }
        try Task.checkCancellation()
        guard client === remote else { throw CancellationError() }
        selectedHostID = payload.hostID
        connectedHostID = payload.hostID
        activeTransport = remote.activeTransport
        connectionState = .connected
        beginWatchingClientState(remote, hostID: payload.hostID)
        await requestPushAuthorizationIfNeeded()
        try Task.checkCancellation()
        guard client === remote else { throw CancellationError() }
        await registerPushIfNeeded(client: remote)
        // 持久化异常时仍返回配对结果，避免强制解包崩溃。
        return hostStore.host(for: payload.hostID) ?? HostInfo(from: payload)
    }

#if DEBUG
    /// Observe a socket-free client through the same watcher used by real connections.
    func observeConnectionForTesting(_ remote: RemoteClient, hostID: String) {
        client = remote
        beginWatchingClientState(remote, hostID: hostID)
    }
#endif

    /// 把底层连接状态同步到界面，避免重连中仍显示「已连接」。
    private func beginWatchingClientState(_ remote: RemoteClient, hostID: String) {
        stateWatchTask?.cancel()
        remote.addReadyHandler { [weak self, weak remote] in
            guard let self, let remote, self.client === remote, remote.isUsable else { return }
            self.connectedHostID = hostID
            self.connectedAccess = remote.confirmedAccess
            self.connectionState = .connected
            self.activeTransport = remote.activeTransport
            if self.deferredPathCheck { self.deferredPathCheck = false; self.handleSceneBecameActive() }
        }
        stateWatchTask = Task { [weak self] in
            var last = remote.state
            var lastTransport = remote.activeTransport
            // When a connected client dropped; nil while ready.
            var droppedAt: Date?
            while !Task.isCancelled {
                let current = remote.state
                let transport = remote.activeTransport
                let inGrace = droppedAt != nil && current != .ready && current != .disconnected
                if current != last || transport != lastTransport || current == .ready || inGrace {
                    last = current
                    lastTransport = transport
                    guard let self, self.client === remote else { return }
                    switch current {
                    case .ready:
                        guard remote.controlConfirmed else {
                            if self.connectionState == .connected {
                                let since = droppedAt ?? Date()
                                droppedAt = since
                                if TransientDropPolicy.shouldShowReconnecting(droppedAt: since) {
                                    self.connectionState = .reconnecting
                                    self.activeTransport = nil
                                }
                            }
                            try? await Task.sleep(for: .milliseconds(200))
                            continue
                        }
                        droppedAt = nil
                        self.connectedAccess = remote.confirmedAccess
                        self.activeTransport = transport
                        self.connectionState = .connected
                        self.connectedHostID = hostID
                    case .connecting, .handshaking, .reconnecting:
                        guard self.connectionState == .connected else {
                            self.activeTransport = transport
                            break
                        }
                        // The immediate reconnect usually lands within milliseconds;
                        // keep the connected bar (and its transport) through the grace.
                        let since = droppedAt ?? Date()
                        droppedAt = since
                        if TransientDropPolicy.shouldShowReconnecting(droppedAt: since) {
                            droppedAt = nil
                            self.activeTransport = transport
                            self.connectionState = .reconnecting
                        }
                    case .disconnected:
                        droppedAt = nil
                        self.connectionState = remote.terminalConnectionError.map { .failed($0) } ?? .disconnected
                        self.connectedAccess = nil
                        self.connectedHostID = nil
                        self.activeTransport = nil
                    }
                    if current == .ready { last = current }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func syncConnectionPresentation() {
        guard let client else { return }
        activeTransport = client.activeTransport
        switch client.state {
        case .ready:
            if client.controlConfirmed {
                connectionState = .connected
                connectedAccess = client.confirmedAccess
                connectedHostID = client.reconnectHost?.hostID
            } else {
                connectionState = .connecting
            }
        case .connecting, .handshaking, .reconnecting:
            // A connected bar is left to the state watcher, which applies the
            // transient-drop grace; flipping here would flash Reconnecting on
            // every return to the foreground even when the reconnect is instant.
            if !TransientDropPolicy.syncKeepsConnectedBar(isConnectedBar: connectionState == .connected) {
                connectionState = .reconnecting
            }
        case .disconnected:
            connectionState = client.terminalConnectionError.map { .failed($0) } ?? .disconnected
            connectedAccess = nil
            connectedHostID = nil
            activeTransport = nil
        }
    }

    func removeHost(_ host: HostInfo) {
        hostStore.removeHost(hostID: host.hostID)
        refreshHosts()
        if connectedHostID == host.hostID || inFlightHostID == host.hostID {
            disconnect(clearSelection: false)
        }
        if selectedHostID == host.hostID {
            selectedHostID = hosts.first?.hostID
        }
    }

    /// hello 带回非空中继地址时写回 Host；当前会话可仍走局域网，下次重连会优先尝试中继兜底。
    private func applyHelloRelayIfNeeded(_ hello: HelloResponse, hostID: String) {
        guard let relay = hello.relayURL, !relay.isEmpty else { return }
        guard var stored = hostStore.host(for: hostID) else { return }
        guard stored.relayURL != relay else { return }
        stored.relayURL = relay
        hostStore.upsertHost(stored)
        refreshHosts()
    }

    /// hello 带回 `local_hints` 时合并写回 Host（有变化才写盘 + 刷新）。
    /// DHCP 换 IP 后下次重连/换网直接用新地址，不必重新配对或等 Bonjour。
    /// 同时把同一份快照同步进 `RemoteClient`，避免抢答仍拿连接时的旧 IP。
    private func applyHelloLocalHintsIfNeeded(_ hello: HelloResponse, hostID: String) {
        guard let hints = hello.localHints, !hints.isEmpty else { return }
        guard let stored = hostStore.host(for: hostID) else { return }
        let merged = stored.mergingLocalHints(hints)
        guard merged.localHints != stored.localHints else { return }
        hostStore.updateLocalHints(hostID: hostID, hints: hints)
        if let refreshed = hostStore.host(for: hostID) {
            client?.syncReconnectHost(refreshed)
        }
        refreshHosts()
    }

    /// hello 带回开发机默认名：只更新 `name`，本地别名照旧优先显示。
    /// 服务端 rename 后手机下次连上自动跟随；已设别名的机器显示不变。
    private func applyHelloHostNameIfNeeded(_ hello: HelloResponse, hostID: String) {
        guard let stored = hostStore.host(for: hostID) else { return }
        let before = stored.displayName
        hostStore.applyHelloHostName(hostID: hostID, name: hello.hostName)
        if hostStore.host(for: hostID)?.displayName != before {
            refreshHosts()
        }
    }

    // MARK: - iOS APNs registration (Mac local notifications live in the Mac shell)

    private func requestPushAuthorizationIfNeeded() async {
        #if os(iOS)
        await PushRegistrar.shared.requestAuthorizationIfNeeded()
        #endif
    }

    private func registerPushIfNeeded(client remote: RemoteClient) async {
        #if os(iOS)
        await PushRegistrar.shared.registerIfNeeded(client: remote)
        #endif
    }

    // MARK: - 网络路径变化

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.x0c.corral.path"))
    }

    private func handlePathUpdate(_ path: NWPath) {
        let signature = pathSignature(path)
        let previous = lastPathSignature
        lastPathSignature = signature
        // 首次回调是基线，不触发重连。
        guard previous != nil, previous != signature else { return }
        guard path.status == .satisfied else { return }
        guard PathReconnectGate.shouldHandlePathChange(
            connectionStateIsConnecting: connectionState == .connecting,
            suppressUntil: suppressPathReconnectUntil
        ) else { deferredPathCheck = true; return }

        // The monitor observes interfaces, not whether this host is reachable.
        // A real encrypted hello decides whether the existing path needs replacement.
        handleSceneBecameActive()
    }

    private func pathSignature(_ path: NWPath) -> String {
        var parts: [String] = [String(describing: path.status)]
        if path.usesInterfaceType(.wifi) { parts.append("wifi") }
        if path.usesInterfaceType(.cellular) { parts.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("eth") }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        return parts.joined(separator: "|")
    }
}

#if os(iOS)
#if canImport(UIKit)
import UIKit
#endif
#endif

/// 跨平台设备名。
enum UIDeviceName {
    static var current: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Corral"
        #endif
    }

    /// Platform label shown in the host's paired-device list.
    static var pairingPlatform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }
}

/// 切开发机时是否要重新建连。
///
/// 已连上时若先改「当前选中」再拿选中项判断「是不是这台」，切到另一台会永远跳过重连，
/// 列表就会继续显示上一台的会话。
nonisolated enum HostConnectionDecision: Sendable {
    static func needsReconnect(
        connectedHostID: String?,
        targetHostID: String,
        isReady: Bool
    ) -> Bool {
        !isReady || connectedHostID != targetHostID
    }
}

extension AppModel {
    /// Identity of the live client, so views restart host subscriptions when it is replaced.
    var clientIdentity: ObjectIdentifier? { client.map(ObjectIdentifier.init) }
}
