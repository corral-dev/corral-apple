import Foundation

@MainActor extension RemoteClient {
    /// 多路并发握手；第一路成功即取消其余。
    ///
    /// 必须非隔离：在主隔离域里 `await receive()` 会占住主线程，超时与其它候选都跑不了。
    /// 不用 TaskGroup：group 退出要等所有子任务结束，而一条连不通地址的 `receive`
    /// 可能挂几十秒，会把已经握手成功的赢家一起卡住。`HandshakeArena` 只等第一个
    /// 赢家，输家立刻被取消并关掉 socket，迟到的赢家也会被关掉——开发机侧不会再
    /// 留下永不确认的僵尸通道。
    nonisolated static func raceHandshakes(
        candidates: [ConnectCandidate],
        devicePrivateKey: Data,
        hostPublicKey: Data,
        overallTimeout: TimeInterval,
        discoveryHost: HostInfo? = nil,
        discover: @escaping @Sendable (String) async -> [String] = { await LanDiscovery().browse(hostID: $0) }
    ) async throws -> HandshakeRace.Win {
        // 没人要的赢家（迟到 / 已取消）直接关 socket。
        let arena = HandshakeArbiter<HandshakeRace.Win> { win in win.close() }
        let raceStart = Date()
        for candidate in candidates {
            arena.launch {
                let race = HandshakeRace(
                    candidate: candidate,
                    devicePrivateKey: devicePrivateKey,
                    hostPublicKey: hostPublicKey
                )
                return try await race.run()
            }
        }
        if let discoveryHost {
            arena.launch {
                let hints = await discover(discoveryHost.hostID)
                try Task.checkCancellation()
                let known = Set(candidates.compactMap { $0.url?.absoluteString })
                var discoveredHost = discoveryHost
                discoveredHost.lastLocalHint = nil
                discoveredHost.localHints = hints
                let snapshot = discoveredHost
                let fresh = await MainActor.run {
                    snapshot.connectCandidates(includeLocal: true)
                        .filter { $0.transport == .local && !known.contains($0.url?.absoluteString ?? "") }
                }
                guard !fresh.isEmpty else { throw CancellationError() }
                // Nested race must not extend the outer budget: pass the remainder.
                let remaining = overallTimeout - Date().timeIntervalSince(raceStart)
                guard remaining > 1 else { throw CancellationError() }
                return try await raceHandshakes(candidates: fresh, devicePrivateKey: devicePrivateKey,
                    hostPublicKey: hostPublicKey, overallTimeout: remaining)
            }
        }
        return try await arena.awaitWinner(overallTimeout: overallTimeout)
    }
}

// MARK: - 单路握手（可并发、可取消）

/// 独立于 `RemoteClient` 的一路握手尝试；失败、超时或取消时自行拆掉会话。
///
/// 关键约束：`URLSessionWebSocketTask.receive` 不响应 Swift Task 取消，只会在 socket
/// 被 `cancel(with:)` 后才返回。所以取消 / 超时必须**立刻关 socket**（见
/// `HandshakeSocketLifecycle`），而不是等 receive 自己醒来；否则连不通的地址会
/// 挂几十秒，开发机侧也会留下已握手、永不确认的僵尸通道占满名额。
nonisolated final class HandshakeRace: @unchecked Sendable {
    struct Win: @unchecked Sendable {
        let webSocket: URLSessionWebSocketTask
        let urlSession: URLSession
        let channelID: Data
        let secureChannel: SecureChannel
        let transport: ConnectionTransport
        /// `ip:port` when `transport == .local`, for sticky last-good.
        let localHint: String?

        /// 赢家没人要（迟到 / 调用方已拆）时必须关掉，不能靠 ARC。
        func close() {
            webSocket.cancel(with: .goingAway, reason: nil)
            urlSession.invalidateAndCancel()
        }
    }

    private let candidate: ConnectCandidate
    private let devicePrivateKey: Data
    private let hostPublicKey: Data

    init(candidate: ConnectCandidate, devicePrivateKey: Data, hostPublicKey: Data) {
        self.candidate = candidate
        self.devicePrivateKey = devicePrivateKey
        self.hostPublicKey = hostPublicKey
    }

    func run() async throws -> Win {
        guard let url = candidate.url else {
            throw RemoteClient.ConnectionError.handshakeFailed("连接地址无效")
        }
        try Task.checkCancellation()

        let config = RemoteWebSocketSession.makeConfiguration()
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.setValue(WireProtocol.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: request)
        let lifecycle = HandshakeSocketLifecycle {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let localHint: String? = {
            guard candidate.transport == .local, let host = url.host else { return nil }
            let port = url.port ?? (url.scheme == "wss" ? 443 : 80)
            return "\(host):\(port)"
        }()

        // 单路超时：到点直接关 socket，让挂着的 receive 立刻报错。
        let timeout = candidate.timeout
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            lifecycle.expire()
        }
        defer { timer.cancel() }

        do {
            let (channel, channelKeys) = try await withTaskCancellationHandler {
                try await Self.performHandshake(
                    task: task,
                    devicePrivateKey: devicePrivateKey,
                    hostPublicKey: hostPublicKey
                )
            } onCancel: {
                lifecycle.close()
            }
            // 握手成功，但期间已被取消 / 超时关掉：不能把关掉的 socket 当赢家。
            guard lifecycle.adopt() else {
                throw lifecycle.didTimeOut ? RemoteClient.ConnectionError.timeout : CancellationError()
            }
            return Win(
                webSocket: task,
                urlSession: session,
                channelID: channel,
                secureChannel: channelKeys,
                transport: candidate.transport,
                localHint: localHint
            )
        } catch {
            lifecycle.close()
            if lifecycle.didTimeOut { throw RemoteClient.ConnectionError.timeout }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func performHandshake(
        task: URLSessionWebSocketTask,
        devicePrivateKey: Data,
        hostPublicKey: Data
    ) async throws -> (channel: Data, keys: SecureChannel) {
        try Task.checkCancellation()
        // 先挂接收再 resume，避免开发机立刻发来的通道分配被丢掉后一直等。
        async let opened = Self.receiveBinary(task)
        task.resume()
        let openRaw = try await opened
        let (openType, channel, _) = try WireFrame.decode(openRaw)
        guard openType == WireProtocol.frameDeviceOpen else {
            throw RemoteClient.ConnectionError.handshakeFailed(
                "期待通道分配，收到 0x\(String(openType, radix: 16))"
            )
        }

        let handshake = try DeviceHandshake(staticPrivate: devicePrivateKey)
        let helloOut = try WireFrame.encode(
            type: WireProtocol.frameHello,
            channelID: channel,
            payload: handshake.helloPayload
        )
        try await task.send(.data(helloOut))

        let helloRaw = try await Self.receiveBinary(task)
        let (helloType, _, helloPayload) = try WireFrame.decode(helloRaw)
        guard helloType == WireProtocol.frameHello else {
            throw RemoteClient.ConnectionError.handshakeFailed(
                "期待握手回应，收到 0x\(String(helloType, radix: 16))"
            )
        }
        try RemoteCryptoKeys.validatePublic(helloPayload, label: "开发机临时公钥")
        let channelKeys = try handshake.complete(
            hostStatic: hostPublicKey,
            hostEphemeral: helloPayload
        )
        return (channel, channelKeys)
    }

    /// Completion-handler receive：async `receive()` 会占住协作线程，抢答超时与其它候选一起饿死。
    private static func receiveBinary(_ task: URLSessionWebSocketTask) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = OneShotThrowingContinuation(continuation)
            task.receive { result in
                switch result {
                case let .success(.data(data)):
                    gate.resume(returning: data)
                case let .success(.string(text)):
                    gate.resume(returning: Data(text.utf8))
                case .success:
                    gate.resume(throwing: RemoteClient.ConnectionError.invalidResponse)
                case let .failure(error):
                    gate.resume(throwing: error)
                }
            }
        }
    }
}
