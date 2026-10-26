import Foundation

@MainActor extension RemoteClient {
    func teardownSocket(keepSubscriptions: Bool) {
        diagnose(.socketTeardown)
        controlConfirmed = false
        confirmedAccess = nil
        hostCapabilities = .empty
        supportsMediaImage = false
        dataBindingTask?.cancel()
        dataBindingTask = nil
        upgradeTask?.cancel()
        upgradeTask = nil
        dataAttachmentGeneration += 1
        receiveTask?.cancel()
        receiveTask = nil
        controlKeepaliveTask?.cancel()
        controlKeepaliveTask = nil
        dataReceiveTask?.cancel()
        dataReceiveTask = nil
        dataKeepaliveTask?.cancel()
        dataKeepaliveTask = nil
        dataRebindTask?.cancel()
        dataRebindTask = nil
        dataPlaneRebindAttempt = 0
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        dataWebSocket?.cancel(with: .goingAway, reason: nil)
        dataWebSocket = nil
        dataURLSession?.invalidateAndCancel()
        dataURLSession = nil
        hostPublicKey = nil
        compressionEnabled = false
        channelID = WireProtocol.zeroChannel
        dataChannelID = WireProtocol.zeroChannel
        controlPlane?.stop()
        controlPlane = nil
        dataPlane?.stop()
        dataPlane = nil
        dataPlaneConfirmed = false
        activeTransport = nil

        for (_, entry) in pendingRequests {
            entry.timeout.cancel()
            entry.continuation.resume(throwing: ConnectionError.notConnected)
        }
        pendingRequests.removeAll()

        if !keepSubscriptions {
            for (_, buckets) in channelSubscribers {
                for (_, subscriber) in buckets {
                    subscriber.finish()
                }
            }
            channelSubscribers.removeAll()
            for (_, subscriber) in wildcardSubscribers {
                subscriber.finish()
            }
            wildcardSubscribers.removeAll()
            readyHandlers.removeAll()
        }
    }

    // MARK: - 收发循环与重连

    func startReceiveLoop(plane: PlaneIO, isControl: Bool) {
        if isControl {
            receiveTask?.cancel()
        } else {
            dataReceiveTask?.cancel()
        }
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let box = try await plane.pump() {
                        self.dispatch(box.message, from: plane, isControl: isControl)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    self.handlePlaneFailure(plane: plane, isControl: isControl, error: error, reason: .receive)
                    break
                }
            }
        }
        if isControl {
            receiveTask = task
            startKeepalive(plane: plane, isControl: true)
        } else {
            dataReceiveTask = task
            startKeepalive(plane: plane, isControl: false)
        }
    }

    /// 每条平面独立探活：约 15 秒 ping 一次；约 45 秒无收包或 ping 失败则走平面失败。
    private func startKeepalive(plane: PlaneIO, isControl: Bool) {
        if isControl {
            controlKeepaliveTask?.cancel()
        } else {
            dataKeepaliveTask?.cancel()
        }
        let task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(RemoteKeepalive.pingInterval))
                        guard !Task.isCancelled else { break }
                        do {
                            try await plane.sendPing()
                        } catch is CancellationError {
                            break
                        } catch {
                            await self?.handlePlaneFailure(plane: plane, isControl: isControl, error: error, reason: .ping)
                            break
                        }
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(RemoteKeepalive.idlePollInterval))
                        guard !Task.isCancelled else { break }
                        let age = Date().timeIntervalSince(plane.lastReceiveAt)
                        if age >= RemoteKeepalive.idleTimeout {
                            await self?.handlePlaneFailure(plane: plane, isControl: isControl, reason: .idleTimeout)
                            break
                        }
                    }
                }
                await group.next()
                group.cancelAll()
                await group.waitForAll()
            }
        }
        if isControl {
            controlKeepaliveTask = task
        } else {
            dataKeepaliveTask = task
        }
    }

    func isCurrentPlane(_ plane: PlaneIO, isControl: Bool) -> Bool {
        (isControl ? controlPlane : dataPlane) === plane
    }

    private func handlePlaneFailure(plane: PlaneIO, isControl: Bool, error: (any Error)? = nil, reason: ClientDiagnosticFailure? = nil) {
        // Cancelling a replaced socket can report URLError.cancelled after its successor is ready.
        guard isCurrentPlane(plane, isControl: isControl) else { return }
        diagnose(.planeFailed, isControl: isControl, error: error, reason: reason)
        if isControl {
            handleReceiveFailure()
        } else {
            guard dataPlane != nil || dataWebSocket != nil else { return }
            teardownDataPlane()
            dataPlaneRebindAttempt = 0
            Task { await self.rebindDataPlane() }
        }
    }

    private func handleReceiveFailure() {
        guard state == .ready else { return }
        teardownSocket(keepSubscriptions: true)
        guard allowReconnect, reconnectHost != nil else {
            state = .disconnected
            return
        }
        state = .reconnecting
        scheduleReconnect(immediate: false)
    }

    func scheduleReconnect(immediate: Bool) {
        diagnose(.reconnectScheduled)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                self.reconnectAttempt += 1
                let delay = ReconnectBackoff.delay(
                    forAttempt: self.reconnectAttempt,
                    hasLocalCandidates: self.hasLocalCandidates
                )
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay * Double.random(in: 0.8...1.2)))
                }
            } else {
                self.reconnectAttempt = 0
            }
            guard !Task.isCancelled, self.allowReconnect, let host = self.reconnectHost else { return }
            self.state = .reconnecting
            do {
                try await self.raceConnect(host: host, includeLocal: self.reconnectIncludeLocal)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.allowReconnect else { return }
                self.state = .reconnecting
                self.scheduleReconnect(immediate: false)
            }
        }
    }

    /// The next race includes a LAN or loopback candidate.
    var hasLocalCandidates: Bool {
        currentCandidates().contains { $0.transport == .local }
    }

    // MARK: - WebSocket 原语

    func attachDataPlane(bind: String, name: String) async throws {
        guard state == .ready, let source = controlPlane, allowReconnect else { throw CancellationError() }
        dataAttachmentGeneration += 1
        let generation = dataAttachmentGeneration
        guard let host = reconnectHost, let publicKey = host.publicKeyData else {
            throw ConnectionError.handshakeFailed("开发机公钥无效")
        }
        let candidates = host.connectCandidates(
            includeLocal: reconnectIncludeLocal,
            defaultRelay: Self.defaultRelayURL,
            bonjourHints: bonjourHints,
            round: dataPlaneRebindAttempt
        )
        guard !candidates.isEmpty || reconnectIncludeLocal else {
            throw ConnectionError.handshakeFailed("没有可用的连接地址")
        }
        // 与第一条相同的抢答规则；不复用上次胜出的具体 URL。
        let win = try await Self.raceHandshakes(
            candidates: candidates,
            devicePrivateKey: devicePrivateKey,
            hostPublicKey: publicKey,
            overallTimeout: PathRaceBudget.overallTimeout,
            discoveryHost: reconnectIncludeLocal ? host : nil,
            discover: addressDiscovery
        )
        // 控制面在抢答期间已经没了：这条数据面没人要，必须关掉而不是挂着。
        guard state == .ready, isCurrentPlane(source, isControl: true), allowReconnect,
              dataAttachmentGeneration == generation, !Task.isCancelled else {
            win.close()
            throw CancellationError()
        }
        teardownDataPlane()
        dataWebSocket = win.webSocket
        dataURLSession = win.urlSession
        dataChannelID = win.channelID
        let adoptedPlane = PlaneIO(win: win)
        dataPlane = adoptedPlane
        startReceiveLoop(plane: adoptedPlane, isControl: false)
        do {
            let raw = try await callRaw(
                WireProtocol.mHello,
                params: WireProtocol.dataHelloParams(bind: bind, name: name),
                plane: adoptedPlane
            )
            guard isCurrentPlane(source, isControl: true), isCurrentPlane(adoptedPlane, isControl: false),
                  !Task.isCancelled else { throw CancellationError() }
            if let ok = raw["ok"] as? Bool, !ok {
                if let error = RemoteCallError(from: raw) { throw error }
                throw ConnectionError.invalidResponse
            }
            dataPlaneConfirmed = true
            lastDataPlaneError = nil
            diagnose(.dataAttached, isControl: false)
            dataPlaneRebindAttempt = 0
        } catch {
            diagnose(.dataAttachFailed, isControl: false, error: error)
            if isCurrentPlane(adoptedPlane, isControl: false) { teardownDataPlane() }
            throw error
        }
    }

    private func teardownDataPlane() {
        if let dataPlane {
            failPendingRequests(on: dataPlane)
        }
        dataAttachmentGeneration += 1
        dataKeepaliveTask?.cancel()
        dataKeepaliveTask = nil
        dataReceiveTask?.cancel()
        dataReceiveTask = nil
        dataWebSocket?.cancel(with: .goingAway, reason: nil)
        dataWebSocket = nil
        dataURLSession?.invalidateAndCancel()
        dataURLSession = nil
        dataChannelID = WireProtocol.zeroChannel
        dataPlane?.stop()
        dataPlane = nil
        dataPlaneConfirmed = false
    }

    /// Requests sent on a plane that is going away will never be answered on it.
    /// Fail them now; callers decide whether to retry (nothing is resent here).
    private func failPendingRequests(on plane: PlaneIO) {
        let id = ObjectIdentifier(plane)
        for (requestID, entry) in pendingRequests where entry.plane == id {
            pendingRequests.removeValue(forKey: requestID)
            entry.timeout.cancel()
            entry.continuation.resume(throwing: ConnectionError.notConnected)
        }
    }

    func rebindDataPlane() async {
        guard allowReconnect, isUsable, let name = lastHelloName, dataPlane == nil, dataBindingTask == nil,
              let source = controlPlane else { return }
        do {
            let raw = try await callRaw(WireProtocol.mHello, params: WireProtocol.controlHelloParams(name: name))
            guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { return }
            if raw["ok"] as? Bool == false { throw RemoteCallError(from: raw) ?? ConnectionError.invalidResponse }
            let hello = try RemoteJSONDecoder.decode(HelloResponse.self, from: raw["d"] ?? [:])
            try confirmControl(hello, source: source)
            let bind = WireProtocol.dataBind(fromHelloPayload: raw["d"] ?? [:])
            hostOffersDataPlane = WireProtocol.shouldAttachDataPlane(dataBind: bind)
            if WireProtocol.shouldAttachDataPlane(dataBind: bind), let bind {
                try await bindDataPlaneOnce(bind: bind, name: name)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { return }
            if case ConnectionError.pairingRequired = error { recoverConnection(after: error); return }
            lastDataPlaneError = error.localizedDescription
            scheduleDataPlaneRebind()
        }
    }

    /// 控制面仍 ready 时按退避重试数据面绑定，上限只限制间隔；不把控制面一起掐掉。
    func scheduleDataPlaneRebind() {
        dataRebindTask?.cancel()
        guard allowReconnect else { return }
        let nextAttempt = min(dataPlaneRebindAttempt + 1, 1_000_000)
        guard DataPlaneRebindPolicy.shouldRetry(
            attempt: nextAttempt,
            controlReady: isUsable,
            dataPlaneAttached: dataPlane != nil
        ) else {
            if state == .ready, dataPlane == nil { diagnose(.dataRetryExhausted, isControl: false) }
            return
        }
        dataPlaneRebindAttempt = nextAttempt
        diagnose(.dataRetryScheduled, isControl: false)
        let delay = DataPlaneRebindPolicy.delay(forAttempt: dataPlaneRebindAttempt)
        dataRebindTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.rebindDataPlane()
        }
    }

    #if DEBUG
    func setConnectionStateForTesting(_ state: State) {
        self.state = state
    }

    struct PlaneCallbacksForTesting {
        let receive: @MainActor ([String: Any]) -> Void
        let fail: @MainActor () -> Void
    }

    /// Install an unstarted socket so tests can deliver the same callbacks as the receive/heartbeat loops.
    func installPlaneForTesting(isControl: Bool) -> PlaneCallbacksForTesting {
        let session = URLSession(configuration: .ephemeral)
        guard let url = URL(string: "ws://127.0.0.1:1") else {
            fatalError("The fixed test socket URL is invalid")
        }
        let socket = session.webSocketTask(with: url)
        let plane = PlaneIO(win: HandshakeRace.Win(
            webSocket: socket,
            urlSession: session,
            channelID: WireProtocol.zeroChannel,
            secureChannel: SecureChannel(
                sendKey: Data(repeating: 0, count: 32),
                recvKey: Data(repeating: 0, count: 32),
                peerStaticPublic: Data(repeating: 0, count: 32)
            ),
            transport: .local,
            localHint: nil
        ))
        if isControl {
            teardownSocket(keepSubscriptions: true)
            webSocket = socket
            urlSession = session
            controlPlane = plane
            state = .ready
        } else {
            teardownDataPlane()
            dataWebSocket = socket
            dataURLSession = session
            dataPlane = plane
        }
        return PlaneCallbacksForTesting(
            receive: { [weak self] message in self?.dispatch(message, from: plane, isControl: isControl) },
            fail: { [weak self] in self?.handlePlaneFailure(plane: plane, isControl: isControl) }
        )
    }
    #endif
}
