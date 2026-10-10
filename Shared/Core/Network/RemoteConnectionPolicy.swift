import Foundation

/// 整轮抢答预算：单路局域网 2s / 中继 8s，整轮不得超过此值，避免 Connecting 挂死。
nonisolated enum PathRaceBudget: Sendable {
    static let overallTimeout: TimeInterval = 10
    /// 已在中继上试直连升级：只花几秒，失败无感留在中继。
    static let upgradeTimeout: TimeInterval = 3
}

// MARK: - 长连接会话与保活（可测）

/// 已建立 WebSocket 的 URLSession 配置。抢答超时只走 `HandshakeRace` 的 `Task.sleep`，禁止写进这里。
nonisolated enum RemoteWebSocketSession: Sendable {
    /// 包间隔超时：7 天。不能用局域网 2 秒 / 中继 8 秒，否则空闲对话会被当成短请求掐掉。
    static let requestTimeout: TimeInterval = 7 * 24 * 60 * 60
    /// 资源存活上限：无限。长连接的寿命由应用层探活与空闲判定接管。
    static let resourceTimeout: TimeInterval = .infinity

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        return config
    }
}

/// 应用层探活节奏。
nonisolated enum RemoteKeepalive: Sendable {
    static let pingInterval: TimeInterval = 15
    static let idleTimeout: TimeInterval = 45
    static let idlePollInterval: TimeInterval = 5
}

/// Control-plane reconnect schedule after a drop.
///
/// The first retry is immediate: a dropped frame or a path blip on the host's
/// own machine or LAN must recover before the user sees Reconnecting. The old
/// 1 → 2 → 4 → 8 s schedule turned one dropped frame into a 23-second banner.
/// With a LAN / loopback candidate the cap stays short; relay-only keeps the
/// longer cap so an unreachable relay is not hammered.
nonisolated enum ReconnectBackoff: Sendable {
    static let localCap: TimeInterval = 4
    static let relayCap: TimeInterval = 30

    static func delay(forAttempt attempt: Int, hasLocalCandidates: Bool) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let exponential = 0.5 * pow(2.0, Double(min(attempt - 2, 6)))
        return min(hasLocalCandidates ? localCap : relayCap, exponential)
    }
}

/// A drop that the immediate reconnect repairs within a moment must not reach
/// the user: the status bar keeps showing connected for `presentationGrace`,
/// and a request issued in the gap waits up to `requestWait` for the new
/// connection instead of failing with "not connected". A real outage still
/// surfaces as Reconnecting after the grace.
nonisolated enum TransientDropPolicy: Sendable {
    static let presentationGrace: TimeInterval = 1.5
    static let requestWait: TimeInterval = 3

    static func shouldShowReconnecting(droppedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(droppedAt) >= presentationGrace
    }

    /// One-shot presentation syncs (return to foreground, path change) must not
    /// override a connected bar; only the grace-aware state watcher may.
    static func syncKeepsConnectedBar(isConnectedBar: Bool) -> Bool {
        isConnectedBar
    }
}

/// 数据面断开后的退避重绑；控制面 ready 时才继续，次数用尽即停。
nonisolated enum DataPlaneRebindPolicy: Sendable {
    static let delayCap: TimeInterval = 30

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let clamped = min(max(attempt, 1) - 1, 5)
        return min(30.0, pow(2.0, Double(clamped)))
    }

    static func shouldRetry(
        attempt: Int,
        controlReady: Bool,
        dataPlaneAttached: Bool
    ) -> Bool {
        controlReady && !dataPlaneAttached && attempt >= 1
    }
}

/// 回到前台时是否必须强制重选路。ready 且已空闲时不能什么都不做。
nonisolated enum ForegroundReconnectDecision: Sendable {
    static func shouldForceReconnect(isReady: Bool, isIdle: Bool) -> Bool {
        isReady && isIdle
    }
}

/// 换网/回前台探测决策（可测的纯逻辑部分）。
///
/// 真探测是 `RemoteClient.probeAndMigrateIfNeeded()`：短超时 hello 成功则
/// 虚惊（保持 connected 不闪断），失败才 force 重连。这里只收敛阈值与
/// 「什么情况下值得探测」的判断，不碰网络与 UI。
///
/// 选路本身不做蜂窝/Wi‑Fi 粗分：局域网与中继始终并行抢答，谁快用谁
/// （蜂窝上也可能经 VLAN/VPN/组网直达开发机）。
nonisolated enum PathProbeDecision: Sendable {
    /// 探测 hello 的超时（秒）。远小于正常 RPC 的 20 秒，路断时尽快走重连。
    static let probeTimeout: TimeInterval = 3

    /// 只有控制面 ready 时探测才有意义；其余状态直接交给现有重连管线。
    static func shouldProbe(isReady: Bool) -> Bool {
        isReady
    }
}

/// 冷启动会同时从「回到前台」和会话列表发起连接。过期那一轮不得拆掉新连接。
nonisolated enum ConnectAttemptGate: Sendable {
    static func shouldReuseInFlight(
        selectedHostID: String?,
        targetHostID: String,
        connectionStateIsBusy: Bool,
        hasClient: Bool
    ) -> Bool {
        connectionStateIsBusy && hasClient && selectedHostID == targetHostID
    }

    static func shouldApplyResult(attempt: Int, current: Int) -> Bool {
        attempt == current
    }
}

/// 冷启动 / 刚连上时，path monitor 误伤抢答的闸门（可单测）。
nonisolated enum PathReconnectGate: Sendable {
    /// 首轮 connect 进行中：完全忽略 path 强制重连。
    static let suppressSeconds: TimeInterval = 8
    /// 连上后再消音一会儿，躲开启动期连续 path 回调。
    static let settleSeconds: TimeInterval = 3

    static func shouldHandlePathChange(
        connectionStateIsConnecting: Bool,
        suppressUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        if connectionStateIsConnecting { return false }
        if let until = suppressUntil, now < until { return false }
        return true
    }
}
