import Foundation

@MainActor extension RemoteClient {
    // MARK: - RPC

    @discardableResult
    func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        let message = try await callRaw(method, params: params)
        if let ok = message["ok"] as? Bool, !ok {
            if let error = RemoteCallError(from: message) {
                throw error
            }
            throw ConnectionError.invalidResponse
        }
        return message["d"] ?? [:]
    }

    /// Typed responses decode off the main actor; callers already re-check their
    /// request revision after this `await`.
    func call<T: Decodable & Sendable>(
        _ method: String,
        params: [String: Any] = [:],
        as type: T.Type
    ) async throws -> T {
        let data = try await call(method, params: params)
        return try await RemoteJSONDecoder.decodeOffMain(type, from: JSONValueBox(value: data))
    }

    func callRaw(
        _ method: String,
        params: [String: Any],
        plane: PlaneIO? = nil,
        timeout timeoutSeconds: TimeInterval = 20
    ) async throws -> [String: Any] {
        if state != .ready {
            try await waitForTransientReconnect()
        }
        let target: PlaneIO
        if let plane {
            target = plane
        } else {
            target = try preferredPlane(for: method)
        }
        nextRequestID += 1
        let requestID = nextRequestID
        let caps: [String: Any] = compressionEnabled ? [:] : [
            "compression": ["deflate"],
        ]
        let compress = method != WireProtocol.mHello && compressionEnabled
        var message = WireMessage.request(
            id: requestID,
            method: method,
            params: params,
            caps: caps
        )
        message[WireProtocol.clientInstanceKey] = Self.clientInstanceID

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if let pending = self?.pendingRequests.removeValue(forKey: requestID) {
                            pending.continuation.resume(throwing: ConnectionError.timeout)
                        }
                    }
                }
                // 先登记再发送：低延迟响应可能在 `send` 返回前抵达，反过来会被收包循环丢弃。
                pendingRequests[requestID] = (continuation, timeout, ObjectIdentifier(target))
                do {
                    // Encrypt + queue is one ordered step on the plane's single writer;
                    // never hand frames to the socket from separate tasks.
                    try target.enqueue(message, compress: compress) { [weak self] error in
                        Task { @MainActor in
                            guard let pending = self?.pendingRequests.removeValue(forKey: requestID) else { return }
                            pending.timeout.cancel()
                            pending.continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    if let pending = pendingRequests.removeValue(forKey: requestID) {
                        pending.timeout.cancel()
                        pending.continuation.resume(throwing: error)
                    }
                }
            }.message
        }, onCancel: {
            Task { [weak self] in
                await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestID) {
                        pending.timeout.cancel()
                        pending.continuation.resume(throwing: CancellationError())
                    }
                }
            }
        })
    }

    /// A request issued while an automatic reconnect is in flight waits briefly
    /// for it (see `TransientDropPolicy`) instead of failing at once.
    private func waitForTransientReconnect() async throws {
        let deadline = Date().addingTimeInterval(TransientDropPolicy.requestWait)
        while state != .ready {
            guard allowReconnect, state != .disconnected, Date() < deadline else {
                throw ConnectionError.notConnected
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func preferredPlane(for method: String) throws -> PlaneIO {
        if let dataPlane, dataPlaneConfirmed, WireProtocol.usesDataPlane(method) {
            return dataPlane
        }
        if let controlPlane {
            return controlPlane
        }
        throw ConnectionError.notConnected
    }

    func pair(code: String, name: String, platform: String = "ios") async throws -> [String: Any] {
        let data = try await call(WireProtocol.mPair, params: [
            "code": code,
            "name": name,
            "platform": platform,
        ]) as? [String: Any]
        return data ?? [:]
    }

    func hello(name: String) async throws -> HelloResponse {
        guard let source = controlPlane else { throw ConnectionError.notConnected }
        lastHelloName = name
        let raw = try await callRaw(WireProtocol.mHello, params: WireProtocol.controlHelloParams(name: name))
        guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { throw CancellationError() }
        if let ok = raw["ok"] as? Bool, !ok {
            if let error = RemoteCallError(from: raw) { throw error }
            throw ConnectionError.invalidResponse
        }
        let payload = raw["d"] as? [String: Any] ?? [:]
        let hello = try RemoteJSONDecoder.decode(HelloResponse.self, from: payload)
        try confirmControl(hello, source: source)
        var caps = hello.capabilities
        if !caps.commandReceipts, WireProtocol.supportsCommandReceipts(fromHelloPayload: payload) {
            caps.commandReceipts = true
        }
        if !caps.toolDetail, WireProtocol.supportsToolDetail(fromHelloPayload: payload) {
            caps.toolDetail = true
        }
        hostCapabilities = caps
        supportsMediaImage = WireProtocol.supportsMediaImage(fromHelloPayload: payload)
        let bind = WireProtocol.dataBind(fromHelloPayload: payload)
        hostOffersDataPlane = WireProtocol.shouldAttachDataPlane(dataBind: bind)
        if !hasDataPlane, WireProtocol.shouldAttachDataPlane(dataBind: bind), let bind {
            do {
                // Client-owned: a cancelled caller must not abort the attach halfway
                // (that tore down the new data plane and scheduled no rebind).
                try await bindDataPlaneOnce(bind: bind, name: name)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { throw CancellationError() }
                // 数据面失败时控制面继续可用；留下 hasDataPlane == false 并按退避重绑。
                lastDataPlaneError = error.localizedDescription
                scheduleDataPlaneRebind()
            }
        }
        guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { throw CancellationError() }
        return hello
    }
}
