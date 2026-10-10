#if DEBUG
import Foundation

/// Read-only user data acceptance; faults close only this inspection client's sockets.
@MainActor
enum MacConnectionInspection {
    private static var started = false
    static func run(model: AppModel, feed: HostSessionFeed) async {
        guard !started, let client = model.client else { return }
        started = true
        var checks: [String: Bool] = [:]
        var messageCounts: [String: Int] = [:]
        checks["initial_confirmed"] = client.isUsable && model.connectionState == .connected
        checks["data_confirmed"] = client.dataPlaneConfirmed
        let original = client.controlPlane
        model.handleSceneBecameActive()
        _ = await client.probeAndMigrateIfNeeded()
        checks["healthy_path_kept"] = client.controlPlane === original && client.isUsable
        let oldData = client.dataPlane
        client.dataWebSocket?.cancel(with: .goingAway, reason: nil)
        checks["data_recovered"] = await wait { client.dataPlaneConfirmed && client.dataPlane !== oldData }
        let old = client.controlPlane
        client.webSocket?.cancel(with: .goingAway, reason: nil)
        checks["control_recovered"] = await wait { client.isUsable && client.controlPlane !== old && client.dataPlaneConfirmed }
        await feed.refresh(showLoading: false)
        checks["list_restored"] = !feed.listStore.windowSessions.isEmpty && feed.loadError == nil
        let originalLocalPreference = client.reconnectIncludeLocal
        if let relay = client.reconnectHost?.relayURL, !relay.isEmpty {
            client.setIncludeLocal(false)
            client.reconnectNow(force: true)
            checks["relay_confirmed"] = await wait { client.isUsable && client.activeTransport == .relay && client.dataPlaneConfirmed }
            await feed.refresh(showLoading: false)
            checks["relay_list_restored"] = !feed.listStore.windowSessions.isEmpty && feed.loadError == nil
        }
        let full = try? await client.call(WireProtocol.mSessionsWatch,
            params: ["limit": 10000], as: SessionsListResponse.self)
        let acceptanceSessions = full?.sessions ?? feed.listStore.windowSessions
        checks["full_table_received"] = full != nil
        for runtime in ["claude", "codex", "opencode", "cursor", "pi"] {
            let candidates = acceptanceSessions.filter { $0.runtime == runtime }
            var count = 0
            for session in candidates.prefix(20) {
                if let response = try? await client.call(WireProtocol.mSessionMessages,
                    params: ["key": session.key, "limit": WireProtocol.messagePageLimit], as: SessionMessagesResponse.self) {
                    count = response.messages.count
                    if count > 0 { break }
                }
            }
            messageCounts[runtime] = count
            checks["history_\(runtime)"] = count > 0
        }
        client.setIncludeLocal(originalLocalPreference)
        if originalLocalPreference { client.reconnectNow(force: true) }
        checks["preferred_path_restored"] = await wait { client.isUsable && client.dataPlaneConfirmed }
        let report: [String: Any] = ["checks": checks, "messageCounts": messageCounts,
            "runtimeCounts": Dictionary(grouping: acceptanceSessions, by: { $0.runtime ?? "unknown" }).mapValues { $0.count }, "transport": String(describing: client.activeTransport), "timestamp": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-connection-acceptance.json"), options: .atomic)
        }
    }

    private static func wait(_ predicate: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < end {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
}
#endif
