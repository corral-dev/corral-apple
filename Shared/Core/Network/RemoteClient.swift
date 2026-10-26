import Foundation

/// WebSocket 远程客户端：中继或直连、握手、RPC、按通道多播事件、断线重连。
///
/// 连接策略：局域网候选与中继候选**并发抢答**，每路独立超时，先握手成功者胜出。
/// 冷启动、重连、换网都走同一套抢答，禁止串行死等局域网。
@MainActor
final class RemoteClient: NSObject {
    enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case handshaking
        case ready
        case reconnecting
    }

    enum ConnectionError: Error, LocalizedError, Sendable {
        case notConnected
        case handshakeFailed(String)
        case sendFailed(String)
        case timeout
        case invalidResponse
        case pairingRequired

        var errorDescription: String? {
            switch self {
            case .notConnected: String(localized: String.LocalizationValue("error.not_connected"))
            case let .handshakeFailed(message): message
            case let .sendFailed(message): message
            case .timeout: String(localized: String.LocalizationValue("error.host_timeout"))
            case .invalidResponse: String(localized: String.LocalizationValue("error.invalid_response"))
            case .pairingRequired: String(localized: String.LocalizationValue("error.pairing_required"))
            }
        }
    }

    let diagnostics = ClientDiagnostics()
    private var diagnosticHeartbeat: Task<Void, Never>?
    var state: State = .disconnected {
        didSet { if oldValue != state { diagnose(.stateChanged) } }
    }
    var controlConfirmed = false
    var confirmedAccess: String?
    var terminalConnectionError: String?
    var isUsable: Bool { state == .ready && controlConfirmed }
    var candidateRound = 0
    var recoveryCheckTask: Task<Bool, Never>?
    var upgradeTask: Task<Void, Never>?
    var dataBindingTask: Task<Void, Error>?

    var channelID: Data = WireProtocol.zeroChannel
    /// 当前生效通路（局域网 / 中继），供界面展示。
    var activeTransport: ConnectionTransport?
    /// 数据面是否已附着。hello / 重绑失败时保持 false，控制面仍可 ready。
    var hasDataPlane: Bool { dataPlane != nil }
    /// 最近一次数据面绑定失败原因；成功附着后清空。
    var lastDataPlaneError: String?
    /// The last control hello carried a data-plane bind token. Health checks
    /// only rebind a missing data plane the host actually offers.
    var hostOffersDataPlane = false
    /// 当前这一轮数据面自动重绑已尝试次数（含进行中的退避）。
    var dataPlaneRebindAttempt = 0
    /// Host feature flags from the last successful control-plane hello.
    var hostCapabilities: HostCapabilities = .empty
    /// Convenience: durable `command_id` receipts are available on this connection.
    var supportsCommandReceipts: Bool { hostCapabilities.commandReceipts }
    /// Convenience: history wire omits tool bodies; fetch via `session.toolDetail`.
    var supportsToolDetail: Bool { hostCapabilities.toolDetail }
    /// Host lists every human prompt of a session, not only the paged-in window.
    var supportsUserPrompts: Bool { hostCapabilities.userPrompts }
    /// Host can preview images that messages cite (`media.image`).
    var supportsMediaImage = false

    /// 距最近一次任一平面成功收包（含 ping 的 pong）的秒数；尚未收包则为 nil。
    var lastReceiveAge: TimeInterval? {
        let times = [controlPlane?.lastReceiveAt, dataPlane?.lastReceiveAt].compactMap { $0 }
        guard let latest = times.max() else { return nil }
        return Date().timeIntervalSince(latest)
    }

    /// 已就绪但超过空闲阈值无收包，或就绪却没有任何收包记录。
    var isIdle: Bool {
        guard state == .ready else { return false }
        guard let age = lastReceiveAge else { return true }
        return age >= RemoteKeepalive.idleTimeout
    }

    var webSocket: URLSessionWebSocketTask?
    var urlSession: URLSession?
    var hostPublicKey: Data?
    var compressionEnabled = false

    /// 数据面第二条物理连接。未附着时全部 RPC 仍走上面的唯一 socket。
    var dataWebSocket: URLSessionWebSocketTask?
    var dataURLSession: URLSession?
    var dataChannelID: Data = WireProtocol.zeroChannel
    var dataPlane: PlaneIO?
    var dataPlaneConfirmed = false
    var dataAttachmentGeneration = 0
    var dataReceiveTask: Task<Void, Never>?
    var dataKeepaliveTask: Task<Void, Never>?
    var dataRebindTask: Task<Void, Never>?
    var controlPlane: PlaneIO?
    var controlKeepaliveTask: Task<Void, Never>?
    var lastHelloName: String?

    var nextRequestID = 0
    /// `plane` is the socket the request was sent on, so a data-plane teardown can fail
    /// its own requests immediately instead of leaving them for the timeout.
    var pendingRequests: [Int: (continuation: CheckedContinuation<WireResponseBox, Error>, timeout: Task<Void, Never>, plane: ObjectIdentifier)] = [:] {
        didSet {
            diagnostics.trackPending(Set(pendingRequests.keys))
            persistDiagnostics()
        }
    }
    var receiveTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    private var raceTask: Task<HandshakeRace.Win, Error>?
    /// 每开一轮抢答 +1；旧轮迟到的赢家用它识别自己已被取代。
    private var raceGeneration = 0

    /// 按通道多播：会话列表、对话、终端可以同时订阅而不互相抢包。
    /// 每个订阅者的保留量有界；落后时读到合并后的 `resync` 标记。
    var channelSubscribers: [String: [UUID: RemoteEventDelivery]] = [:]
    var wildcardSubscribers: [UUID: RemoteEventDelivery] = [:]
    /// 慢消费者缺口重同步通知的合并状态。
    var gapResyncScheduled = false
    var lastGapResyncAt: Date?
    /// 重连成功后通知上层重新发起 watch（服务端连接级订阅不会自动恢复）。
    var readyHandlers: [UUID: @MainActor () -> Void] = [:]
    private var hasBeenReady = false

    let addressDiscovery: @Sendable (String) async -> [String]
    let devicePrivateKey: Data
    /// Identifies this app process to the host (see `WireProtocol.clientInstanceKey`).
    nonisolated static let clientInstanceID = UUID().uuidString

    /// 重连按「这台开发机」重新抢答，不复用上次成功的具体地址。
    var reconnectHost: HostInfo?
    var reconnectIncludeLocal = true
    /// Bonjour 发现的候选（`LanDiscovery` 产出，见 `connect(host:includeLocal:bonjourHints:)`）。
    /// 只追加为 direct 候选，排在静态 hints 之后、中继之前；`attachDataPlane`
    /// 走同一份，数据面与控制面抢答规则一致。
    var bonjourHints: [String] = []
    var reconnectAttempt = 0
    var allowReconnect = true

    init(devicePrivateKey: Data, addressDiscovery: @escaping @Sendable (String) async -> [String] = { await LanDiscovery().browse(hostID: $0) }) {
        self.devicePrivateKey = devicePrivateKey
        self.addressDiscovery = addressDiscovery
        super.init()
        diagnose(.created)
        diagnosticHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self != nil else { return }
                self?.persistDiagnostics()
            }
        }
    }

    convenience init(hostStore: HostStore = .shared) throws {
        let key = try hostStore.loadOrCreateDevicePrivateKey()
        self.init(devicePrivateKey: key)
    }

    // MARK: - 连接

    /// Open-source default: no shared relay. Use the URL from pairing (`r=`)
    /// or an operator-configured host entry. Never bake a maintainer hostname here.
    static let defaultRelayURL = ""

    func connect(relayURL: URL, hostID: String, hostPublicKey: Data) async throws {
        let host = HostInfo(
            hostID: hostID,
            name: hostID,
            publicKeyHex: hostPublicKey.map { String(format: "%02x", $0) }.joined(),
            relayURL: relayURL.absoluteString,
            localHints: []
        )
        try await connect(host: host, includeLocal: false)
    }

    func connectDirect(wsURL: URL, hostPublicKey: Data) async throws {
        // Direct-only transition path; do not invent a shared fallback relay.
        let host = HostInfo(
            hostID: "direct",
            name: "direct",
            publicKeyHex: hostPublicKey.map { String(format: "%02x", $0) }.joined(),
            relayURL: nil,
            localHints: [wsURL.absoluteString]
        )
        try await connect(host: host, includeLocal: true)
    }

    /// 并发抢答连接：局域网与中继同时发起，先成功者胜出。
    /// `bonjourHints` 只追加为 direct 候选（见 `LanDiscovery`），默认空保持兼容。
    func connect(host: HostInfo, includeLocal: Bool = true, bonjourHints: [String] = []) async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectHost = host
        reconnectIncludeLocal = includeLocal
        self.bonjourHints = bonjourHints
        terminalConnectionError = nil
        candidateRound = 0
        allowReconnect = true
        try await raceConnect(host: host, includeLocal: includeLocal)
    }

    /// 当前这轮抢答会用的候选（静态 hints → Bonjour → 中继）。
    /// 供界面诊断与单测；不触发连接。
    func currentCandidates() -> [ConnectCandidate] {
        guard let host = reconnectHost else { return [] }
        return host.connectCandidates(
            includeLocal: reconnectIncludeLocal,
            defaultRelay: Self.defaultRelayURL,
            bonjourHints: bonjourHints
        )
    }

    /// 更新 Bonjour 候选（不触发重连，下一轮抢答生效）。
    func setBonjourHints(_ hints: [String]) {
        bonjourHints = hints
    }

    /// 更新是否在下一轮抢答里带局域网候选（不立刻重连）。
    func setIncludeLocal(_ includeLocal: Bool) {
        reconnectIncludeLocal = includeLocal
    }

    /// 把 HostStore 里已合并的局域网 hints 同步进下一轮抢答用的快照。
    /// `AppModel.applyHelloLocalHintsIfNeeded` 写盘后调用，避免 reconnect 仍拿旧 IP。
    func syncReconnectHost(_ host: HostInfo) {
        guard reconnectHost?.hostID == host.hostID else { return }
        reconnectHost = host
    }

    /// hello / 探测带回的 `local_hints`：更新抢答快照并写回 HostStore。
    /// 发现只生产候选；这里只消费合并结果，不耦合 Bonjour。
    @discardableResult
    func absorbLocalHints(_ hints: [String]) -> Bool {
        let cleaned = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty, let host = reconnectHost else { return false }
        let updated = host.applyingFreshLocalHints(cleaned)
        guard updated.localHints != host.localHints else { return false }
        reconnectHost = updated
        HostStore.shared.updateLocalHints(hostID: updated.hostID, hints: cleaned)
        return true
    }

    /// 抢答前从 HostStore 拉最新 Host（含 hello 已刷新的 localHints）。
    private func refreshReconnectHostFromStore() {
        guard let id = reconnectHost?.hostID,
              let fresh = HostStore.shared.host(for: id)
        else { return }
        reconnectHost = fresh
    }

    /// 抢答主体；重连任务也会调用——不取消 `reconnectTask`，避免把自己掐死。
    func raceConnect(host: HostInfo, includeLocal: Bool) async throws {
        reconnectHost = host
        refreshReconnectHostFromStore()
        let raceHost = reconnectHost ?? host
        guard let publicKey = raceHost.publicKeyData else {
            throw ConnectionError.handshakeFailed("开发机公钥无效")
        }
        let candidates = raceHost.connectCandidates(
            includeLocal: includeLocal,
            defaultRelay: Self.defaultRelayURL,
            bonjourHints: bonjourHints,
            round: candidateRound
        )
        candidateRound += 1
        guard !candidates.isEmpty || includeLocal else {
            throw ConnectionError.handshakeFailed("没有可用的连接地址")
        }

        raceTask?.cancel()
        raceTask = nil
        hostPublicKey = publicKey
        activeTransport = nil
        teardownSocket(keepSubscriptions: true)
        if state != .reconnecting {
            state = .connecting
        }

        // detached：握手不得绑在主隔离域。整轮硬顶、输家与迟到赢家关 socket
        // 都在 HandshakeArena 里完成；这里只负责「这轮是否还算数」。
        let raceStart = ContinuousClock.now
        diagnose(.raceStarted)
        let deviceKey = devicePrivateKey
        let discoveryHost = includeLocal ? raceHost : nil
        let discover = addressDiscovery
        let race = Task.detached(priority: .userInitiated) {
            try await Self.raceHandshakes(
                candidates: candidates,
                devicePrivateKey: deviceKey,
                hostPublicKey: publicKey,
                overallTimeout: PathRaceBudget.overallTimeout,
                discoveryHost: discoveryHost,
                discover: discover
            )
        }
        raceTask = race
        raceGeneration += 1
        let generation = raceGeneration
        let win: HandshakeRace.Win
        do {
            // 调用方（重连任务）被取消时必须把这轮抢答一起取消，否则它会在
            // 后台悄悄握手成功并留下一条谁也不管的连接（开发机侧就是僵尸通道）。
            win = try await withTaskCancellationHandler {
                try await race.value
            } onCancel: {
                race.cancel()
            }
        } catch {
            diagnose(error is CancellationError ? .raceCancelled : .raceFailed, durationMs: raceStart.duration(to: .now).milliseconds, error: error)
            if raceGeneration == generation { raceTask = nil }
            throw error
        }
        // 这轮已被更新的一轮取代、或客户端已 disconnect：赢家也不能用，立即关掉。
        guard raceGeneration == generation, allowReconnect, !Task.isCancelled else {
            diagnose(.staleWinner)
            win.close()
            throw CancellationError()
        }
        raceTask = nil
        adopt(win)
        diagnose(.raceWon, durationMs: raceStart.duration(to: .now).milliseconds)
    }

    /// 前台回来或换网时重连。`force` 为真时即便当前已就绪 / 卡在 connecting 也重新抢答。
    func reconnectNow(force: Bool = false) {
        guard allowReconnect, reconnectHost != nil else { return }
        if force {
            // 正在 connecting 也必须能打断——否则主线程抢答挂死时换网/回前台全无效。
            raceTask?.cancel()
            reconnectTask?.cancel()
            if state == .ready || state == .connecting || state == .handshaking {
                state = .reconnecting
                activeTransport = nil
            }
            scheduleReconnect(immediate: true)
            return
        }
        if state == .ready || state == .connecting || state == .handshaking {
            return
        }
        scheduleReconnect(immediate: true)
    }

    /// 换网/回前台时的轻量探测：发一次短超时 hello，路还通就什么都不做。
    ///
    /// 成功返回 false（虚惊，调用方保持 connected 不闪断）；失败则走现有
    /// force 重连并返回 true（调用方置 reconnecting）。只改自身 state，不碰 UI。
    /// 重连后的会话恢复复用现有机制：`ConversationStore.repullAfterReconnect`
    /// + `reconcilePendingCommands`，绝不自动重发 ambiguous 命令。
    func probeAndMigrateIfNeeded() async -> Bool {
        if let recoveryCheckTask { return await recoveryCheckTask.value }
        let task = Task { await self.validateCurrentPath() }
        recoveryCheckTask = task
        defer { recoveryCheckTask = nil }
        return await task.value
    }

    /// 控制面仍就绪但数据面丢失时，回到前台立即重绑，不必等低频重试。
    func retryDataPlaneIfNeeded() {
        guard isUsable, hostOffersDataPlane, !hasDataPlane, dataBindingTask == nil else { return }
        dataRebindTask?.cancel()
        dataRebindTask = nil
        dataPlaneRebindAttempt = 0
        Task { await self.rebindDataPlane() }
    }

    private func adopt(_ win: HandshakeRace.Win) {
        guard allowReconnect else {
            // disconnect() already happened; a late winner must not resurrect the client.
            win.close()
            return
        }
        // 绝不覆盖一条还开着的 socket：被覆盖的那条会在开发机侧一直算「在线」
        // 并占住通道名额，直到 App 被杀。
        if webSocket != nil || dataWebSocket != nil {
            teardownSocket(keepSubscriptions: true)
        }
        let wasReconnect = hasBeenReady || state == .reconnecting
        webSocket = win.webSocket
        urlSession = win.urlSession
        channelID = win.channelID
        activeTransport = win.transport
        state = .ready
        hasBeenReady = true
        let adoptedPlane = PlaneIO(win: win)
        controlPlane = adoptedPlane
        startReceiveLoop(plane: adoptedPlane, isControl: true)
        if win.transport == .local, let hint = win.localHint, let hostID = reconnectHost?.hostID {
            Task { @MainActor in
                guard self.isCurrentPlane(adoptedPlane, isControl: true) else { return }
                HostStore.shared.rememberLastLocalHint(hostID: hostID, hint: hint)
                if var host = self.reconnectHost {
                    host.lastLocalHint = hint
                    self.reconnectHost = host
                }
            }
        }
        if wasReconnect, let name = lastHelloName {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.hello(name: name)
                    guard self.isCurrentPlane(adoptedPlane, isControl: true), self.isUsable else { return }
                    self.notifyReadyHandlers()
                    self.scheduleLocalUpgrade()
                } catch {
                    guard self.isCurrentPlane(adoptedPlane, isControl: true) else { return }
                    self.recoverConnection(after: error)
                }
            }
        }
    }

    /// 已在中继上但手里有局域网地址时，花几百毫秒试一次直连；成功就无感换路。
    /// 失败保持中继，绝不把界面打回 Connecting。
    func tryUpgradeToLocalIfNeeded() async {
        guard state == .ready, activeTransport == .relay, reconnectIncludeLocal,
              let source = controlPlane else { return }
        refreshReconnectHostFromStore()
        guard let host = reconnectHost, let publicKey = host.publicKeyData else { return }
        let locals = host.connectCandidates(
            includeLocal: true,
            defaultRelay: "",
            bonjourHints: bonjourHints
        ).filter { $0.transport == .local }
        do {
            let win = try await Self.raceHandshakes(
                candidates: locals,
                devicePrivateKey: devicePrivateKey,
                hostPublicKey: publicKey,
                overallTimeout: PathRaceBudget.upgradeTimeout,
                discoveryHost: host,
                discover: addressDiscovery
            )
            guard state == .ready, activeTransport == .relay,
                  isCurrentPlane(source, isControl: true), !Task.isCancelled else {
                win.close()
                return
            }
            do {
                try await Self.validateUpgrade(win, hostID: host.hostID, name: lastHelloName ?? "Corral")
            } catch {
                win.close()
                return
            }
            guard isCurrentPlane(source, isControl: true), allowReconnect, !Task.isCancelled else {
                win.close()
                return
            }
            // In-flight RPCs are tied to the old plane: swapping now would fail
            // them all. Stay on relay; the next upgrade attempt retries when idle.
            guard pendingRequests.isEmpty else {
                win.close()
                return
            }
            teardownSocket(keepSubscriptions: true)
            adopt(win)
        } catch {
            // Stay on relay — upgrade is best-effort only.
        }
    }

    func disconnect() {
        allowReconnect = false
        recoveryCheckTask?.cancel()
        recoveryCheckTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        raceTask?.cancel()
        raceTask = nil
        teardownSocket(keepSubscriptions: false)
        reconnectHost = nil
        activeTransport = nil
        hasBeenReady = false
        hostCapabilities = .empty
        supportsMediaImage = false
        state = .disconnected
        diagnose(.disconnected)
    }
}
