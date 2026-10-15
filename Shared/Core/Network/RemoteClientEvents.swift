import Foundation

@MainActor extension RemoteClient {
    /// 注册「通道已就绪」回调；返回用于取消注册的标识。
    @discardableResult
    func addReadyHandler(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        readyHandlers[id] = handler
        return id
    }

    func removeReadyHandler(_ id: UUID) {
        readyHandlers[id] = nil
    }

    func notifyReadyHandlers() {
        let handlers = Array(readyHandlers.values)
        for handler in handlers {
            handler()
        }
    }

    /// APNs/local notification delivery is independent of the live socket.
    /// Reconcile retained subscriptions only on the notification's current host.
    @discardableResult
    func refreshAfterNotification(hostID: String?, sessionKey: String?) -> Bool {
        guard isUsable, let hostID, hostID == reconnectHost?.hostID,
              let sessionKey, !sessionKey.isEmpty else { return false }
        notifyReadyHandlers()
        return true
    }

    // MARK: - 事件订阅（多播）

    /// 订阅指定通道；返回的流在取消订阅或 disconnect 时结束。
    func subscribe(channel: String) -> AsyncStream<RemoteEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            channelSubscribers[channel, default: [:]][id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.channelSubscribers[channel]?[id] = nil
                    if self?.channelSubscribers[channel]?.isEmpty == true {
                        self?.channelSubscribers[channel] = nil
                    }
                }
            }
        }
    }

    /// 订阅全部事件（调试 / 全局泵）。
    func subscribeAll() -> AsyncStream<RemoteEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            wildcardSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.wildcardSubscribers[id] = nil
                }
            }
        }
    }

    func dispatch(_ message: [String: Any], from plane: PlaneIO, isControl: Bool) {
        guard isCurrentPlane(plane, isControl: isControl), !Task.isCancelled else { return }
        dispatch(message)
    }

    func dispatch(_ message: [String: Any]) {
        let kind = message["t"] as? String
        switch kind {
        case "res":
            if let wire = message["wire"] as? [String: Any],
               wire["compression"] as? String == "deflate" {
                compressionEnabled = true
            }
            // 服务端偶发把 id 编成浮点；对不上时不要误 resume id=0 的请求。
            let id: Int?
            if let intID = message["id"] as? Int {
                id = intID
            } else if let doubleID = message["id"] as? Double {
                id = Int(doubleID)
            } else if let stringID = message["id"] as? String, let parsed = Int(stringID) {
                id = parsed
            } else {
                id = nil
            }
            if let id, let pending = pendingRequests.removeValue(forKey: id) {
                pending.timeout.cancel()
                pending.continuation.resume(returning: WireResponseBox(value: message))
                diagnose(message["ok"] as? Bool == false ? .responseRejected : .responseReceived)
            } else {
                diagnose(id == nil ? .malformedResponse : .orphanResponse)
            }
        case "evt":
            if let channel = message["c"] as? String {
                // 事件载荷偶发直接是数组/标量时，包一层避免上层强转崩溃或静默丢事件。
                let data: [String: Any]
                if let dict = message["d"] as? [String: Any] {
                    data = dict
                } else if let value = message["d"] {
                    data = ["value": value]
                } else {
                    data = [:]
                }
                let event = RemoteEvent(channel: channel, data: data)
                if let buckets = channelSubscribers[channel] {
                    for (_, continuation) in buckets {
                        continuation.yield(event)
                    }
                }
                for (_, continuation) in wildcardSubscribers {
                    continuation.yield(event)
                }
            }
        default:
            break
        }
    }
}
