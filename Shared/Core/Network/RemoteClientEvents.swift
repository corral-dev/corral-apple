import Foundation

/// One bounded multicast subscriber.
///
/// The stream is pull-based (`AsyncStream(unfolding:)`), so retention is exactly
/// what this queue holds: at most `capacity` events and `maxPendingBytes` of
/// payload. A consumer that falls behind loses events *explicitly*: the queue is
/// released, and the next element it reads is one coalesced `resync` marker for
/// that channel. Nothing is buffered without limit and nothing is dropped while
/// pretending the sequence is complete.
@MainActor
final class RemoteEventDelivery {
    /// Events retained while the consumer is not reading.
    static let capacity = 16
    /// Upper bound of the retained payload estimate. A single legal event
    /// (wire messages are capped at 4 MiB) always fits alone.
    static let maxPendingBytes = 8 * 1024 * 1024

    enum Outcome {
        case enqueued
        /// This event started a gap: the queue was released and one marker follows.
        case crossedGap
        /// The gap is still pending; this event is covered by the snapshot.
        case droppedInGap
        /// The consumer finished the stream; the client drops this subscriber.
        case terminated
    }

    private var queue: [(event: RemoteEvent, size: Int)] = []
    private var queuedBytes = 0
    private var gapPending = false
    private var dropped = 0
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// Wildcard subscriptions learn the channel from the events they receive so
    /// the marker lands next to the lost data.
    private var lastChannel: String

    init(channel: String) {
        lastChannel = channel
    }

    var isGapped: Bool { gapPending }

    /// Retained events and bytes, for diagnostics and tests.
    var retentionDepth: (events: Int, bytes: Int) { (queue.count, queuedBytes) }

    func push(_ event: RemoteEvent, size: Int) -> Outcome {
        guard !finished else { return .terminated }
        lastChannel = event.channel
        if gapPending {
            dropped += 1
            return .droppedInGap
        }
        if queue.count >= Self.capacity || (queuedBytes + size > Self.maxPendingBytes && !queue.isEmpty) {
            // A consumer that cannot keep up would only replay a truncated
            // sequence: release it and answer with the gap marker instead.
            queue.removeAll()
            queuedBytes = 0
            gapPending = true
            dropped = 1
            wake()
            return .crossedGap
        }
        queue.append((event, size))
        queuedBytes += size
        wake()
        return .enqueued
    }

    /// Next element: the coalesced gap marker first when events were lost, then
    /// the retained events; `nil` once the stream is finished.
    func next() async -> RemoteEvent? {
        while true {
            if let element = take() { return element }
            if finished { return nil }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Re-check after parking: work may have arrived in between.
                if gapPending || !queue.isEmpty || finished {
                    continuation.resume()
                    return
                }
                waiter = continuation
            }
        }
    }

    /// Teardown or connection replacement: end the stream and release everything.
    func finish() {
        finished = true
        queue.removeAll()
        queuedBytes = 0
        gapPending = false
        dropped = 0
        wake()
    }

    private func wake() {
        let pending = waiter
        waiter = nil
        pending?.resume()
    }

    private func take() -> RemoteEvent? {
        if gapPending {
            gapPending = false
            let lost = dropped
            dropped = 0
            return RemoteEvent(channel: lastChannel, data: ["resync": true, "dropped": lost])
        }
        guard !queue.isEmpty else { return nil }
        let head = queue.removeFirst()
        queuedBytes -= head.size
        return head.event
    }
}

/// Cheap, bounded estimate of a decoded event payload. Its only job is
/// retention accounting; the large bodies (strings) are counted in full and the
/// node budget ends pathological walks.
nonisolated enum RemoteEventSizing {
    private static let nodeBudget = 20_000

    static func estimatedBytes(of value: Any) -> Int {
        var nodes = nodeBudget
        return measure(value, nodes: &nodes)
    }

    private static func measure(_ value: Any, nodes: inout Int) -> Int {
        guard nodes > 0 else { return 0 }
        nodes -= 1
        switch value {
        case let string as String:
            return 16 + string.utf8.count
        case let dictionary as [String: Any]:
            var total = 32
            for (key, item) in dictionary {
                total += 16 + key.utf8.count + measure(item, nodes: &nodes)
                if nodes <= 0 { break }
            }
            return total
        case let array as [Any]:
            var total = 32
            for item in array {
                total += measure(item, nodes: &nodes)
                if nodes <= 0 { break }
            }
            return total
        case let data as Data:
            return 16 + data.count
        case is NSNull:
            return 8
        default:
            return 16
        }
    }
}

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

    // MARK: - 事件订阅（多播，有界）

    /// 订阅指定通道；返回的流在取消订阅或 disconnect 时结束。
    ///
    /// Retention per subscriber is bounded; a consumer that falls behind reads
    /// one coalesced `resync` marker instead of an unbounded backlog.
    func subscribe(channel: String) -> AsyncStream<RemoteEvent> {
        let id = UUID()
        let delivery = RemoteEventDelivery(channel: channel)
        channelSubscribers[channel, default: [:]][id] = delivery
        return AsyncStream(unfolding: {
            await delivery.next()
        }, onCancel: { [weak self] in
            Task { @MainActor in
                delivery.finish()
                self?.removeSubscriber(channel: channel, id: id)
            }
        })
    }

    /// 订阅全部事件（调试 / 全局泵）。
    func subscribeAll() -> AsyncStream<RemoteEvent> {
        let id = UUID()
        let delivery = RemoteEventDelivery(channel: "")
        wildcardSubscribers[id] = delivery
        return AsyncStream(unfolding: {
            await delivery.next()
        }, onCancel: { [weak self] in
            Task { @MainActor in
                delivery.finish()
                self?.wildcardSubscribers[id] = nil
            }
        })
    }

    private func removeSubscriber(channel: String, id: UUID) {
        channelSubscribers[channel]?[id] = nil
        if channelSubscribers[channel]?.isEmpty == true {
            channelSubscribers[channel] = nil
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
                deliver(RemoteEvent(channel: channel, data: data), channel: channel)
            }
        default:
            break
        }
    }

    /// Multicast one event with bounded retention per subscriber.
    private func deliver(_ event: RemoteEvent, channel: String) {
        let size = RemoteEventSizing.estimatedBytes(of: event.data)
        var terminatedChannels: [UUID] = []
        var terminatedWildcards: [UUID] = []
        var gapped = false

        if let buckets = channelSubscribers[channel] {
            for (id, subscriber) in buckets {
                switch subscriber.push(event, size: size) {
                case .enqueued, .droppedInGap: break
                case .crossedGap: gapped = true
                case .terminated: terminatedChannels.append(id)
                }
            }
        }
        for (id, subscriber) in wildcardSubscribers {
            switch subscriber.push(event, size: size) {
            case .enqueued, .droppedInGap: break
            case .crossedGap: gapped = true
            case .terminated: terminatedWildcards.append(id)
            }
        }

        for id in terminatedChannels {
            channelSubscribers[channel]?[id] = nil
        }
        if channelSubscribers[channel]?.isEmpty == true {
            channelSubscribers[channel] = nil
        }
        for id in terminatedWildcards {
            wildcardSubscribers[id] = nil
        }

        if gapped { noteEventGap() }
    }

    /// A slow consumer lost events. Recovery is explicit and coalesced: the
    /// subscriber reads one `resync` marker on its own channel, and ready
    /// handlers re-pull list/watch/terminal state at most once a second, however
    /// many subscribers overflowed.
    private func noteEventGap() {
        diagnose(.eventGap)
        scheduleGapResync()
    }

    private func scheduleGapResync() {
        guard !gapResyncScheduled else { return }
        gapResyncScheduled = true
        let spacing: TimeInterval = 1
        let elapsed = lastGapResyncAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, spacing - elapsed)
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.gapResyncScheduled = false
            self.lastGapResyncAt = Date()
            // Existing re-pull path: list re-watch, conversation catch-up,
            // screen watch and terminal snapshot. Bounded and idempotent.
            self.notifyReadyHandlers()
        }
    }
}
