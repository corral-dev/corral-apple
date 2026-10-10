import Foundation

@MainActor extension RemoteClient {
    /// The encrypted host response, rather than socket creation, establishes usability.
    func confirmControl(_ hello: HelloResponse, source: PlaneIO) throws {
        guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { throw CancellationError() }
        guard hello.paired else { throw ConnectionError.pairingRequired }
        if let id = hello.hostID, let expected = reconnectHost?.hostID, expected != "direct", id != expected {
            throw ConnectionError.invalidResponse
        }
        reconnectAttempt = 0
        controlConfirmed = true
        confirmedAccess = hello.access
        terminalConnectionError = nil
        _ = absorbLocalHints(hello.localHints ?? [])
        if let relay = hello.relayURL, var host = reconnectHost {
            host.relayURL = relay
            reconnectHost = host
            if var stored = HostStore.shared.host(for: host.hostID), stored.relayURL != relay {
                stored.relayURL = relay
                HostStore.shared.upsertHost(stored)
            }
        }
    }

    /// Retry only transport failures; never erase a pairing or replay a command.
    func recoverConnection(after error: Error) {
        guard allowReconnect, !(error is CancellationError) else { return }
        if case ConnectionError.pairingRequired = error {
            let message = error.localizedDescription
            disconnect()
            terminalConnectionError = message
            return
        }
        if case ConnectionError.invalidResponse = error {
            let message = error.localizedDescription
            disconnect()
            terminalConnectionError = message
            return
        }
        teardownSocket(keepSubscriptions: true)
        state = .reconnecting
        scheduleReconnect(immediate: false)
    }

    func validateCurrentPath() async -> Bool {
        guard state == .ready, let name = lastHelloName, let source = controlPlane else { return false }
        do {
            // A health check must not issue an unused data-binding token on every activation.
            let raw = try await callRaw(WireProtocol.mHello, params: ["name": name], timeout: PathProbeDecision.probeTimeout)
            guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { return false }
            if raw["ok"] as? Bool == false { throw RemoteCallError(from: raw) ?? ConnectionError.invalidResponse }
            let hello = try RemoteJSONDecoder.decode(HelloResponse.self, from: raw["d"] ?? [:])
            try confirmControl(hello, source: source)
            retryDataPlaneIfNeeded()
            scheduleLocalUpgrade()
            return false
        } catch {
            guard isCurrentPlane(source, isControl: true), !Task.isCancelled else { return false }
            recoverConnection(after: error)
            return true
        }
    }

    func scheduleLocalUpgrade() {
        guard upgradeTask == nil, isUsable, activeTransport == .relay, reconnectIncludeLocal else { return }
        upgradeTask = Task { [weak self] in
            guard let self else { return }
            await self.tryUpgradeToLocalIfNeeded()
            self.upgradeTask = nil
        }
    }

    /// Foreground, hello and automatic retries share one binding operation.
    func bindDataPlaneOnce(bind: String, name: String) async throws {
        if let dataBindingTask { try await dataBindingTask.value; return }
        guard let source = controlPlane, isUsable else { throw CancellationError() }
        let task = Task { try await self.attachDataPlane(bind: bind, name: name) }
        dataBindingTask = task
        defer { if isCurrentPlane(source, isControl: true) { dataBindingTask = nil } }
        try await task.value
    }
}

nonisolated extension RemoteClient {
    /// Verify the new path before closing a healthy old one. A temporary instance
    /// id keeps the host from superseding that old control socket during validation.
    static func validateUpgrade(_ win: HandshakeRace.Win, hostID: String, name: String) async throws {
        let plane = PlaneIO(win: win)
        defer { plane.stop() }
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(PathProbeDecision.probeTimeout))
            if !Task.isCancelled { win.close() }
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            var request = WireMessage.request(id: -1, method: WireProtocol.mHello, params: ["name": name])
            request[WireProtocol.clientInstanceKey] = "path-check-" + UUID().uuidString
            try plane.enqueue(request, compress: false)
            while !Task.isCancelled {
                guard let box = try await plane.pump() else { continue }
                let message = box.message
                guard message["t"] as? String == "res", message["id"] as? Int == -1 else { continue }
                guard message["ok"] as? Bool != false else { throw ConnectionError.invalidResponse }
                let hello = try RemoteJSONDecoder.decode(HelloResponse.self, from: message["d"] ?? [:])
                guard hello.paired, hello.hostID == nil || hello.hostID == hostID else { throw ConnectionError.pairingRequired }
                try Task.checkCancellation()
                return
            }
            throw ConnectionError.invalidResponse
        } onCancel: { win.close() }
    }
}
