import Foundation

// MARK: - 单平面收发（解密/解压/JSON 不进主隔离域）

/// 一条物理 WebSocket 的加解密与收包。`pump` 在调用方的等待点之外完成 unpack，
/// 主隔离域只拿到已解码的小对象。
///
/// Sending is strictly ordered: the encryption counter is assigned and the frame
/// is admitted in one locked step, and a single writer loop awaits each `send`
/// before starting the next. Apple does not document ordering for concurrent
/// `URLSessionWebSocketTask.send` calls, and the host drops the channel on the
/// first out-of-order counter (`加密帧顺序异常`), so nothing may send around it.
///
/// Admission is bounded (`PlaneOutgoingBudget`): queued plus in-flight frames
/// and bytes have a hard ceiling, so a blocked socket or a stalled event loop
/// cannot grow the backlog without limit. A full queue resets this plane — the
/// socket is closed so the transport rebinds and consumers resync — instead of
/// dropping encrypted frames or reporting an unsent request as delivered.
nonisolated final class PlaneIO: @unchecked Sendable {
    /// A send that has not completed by then means the socket is wedged
    /// (`send` can hang without returning or throwing); the plane is torn down.
    static let sendTimeout: TimeInterval = 30

    /// `WireFrame` header (2 + 16 bytes) plus ChaCha20-Poly1305 counter and tag.
    static let frameOverheadBytes = 2 + WireProtocol.channelIDLength + 8 + 16

    let webSocket: URLSessionWebSocketTask
    let urlSession: URLSession
    let channelID: Data
    private let secureChannel: SecureChannel
    private let cryptoLock = NSLock()
    private let receiveLock = NSLock()
    private var lastReceiveDate = Date()
    private let outbox: PlaneOutbox
    private let writer: Task<Void, Never>

    var lastReceiveAt: Date {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        return lastReceiveDate
    }

    init(win: HandshakeRace.Win, budget: PlaneOutgoingBudget = .standard) {
        self.webSocket = win.webSocket
        self.urlSession = win.urlSession
        self.channelID = win.channelID
        self.secureChannel = win.secureChannel
        let outbox = PlaneOutbox(budget: budget)
        self.outbox = outbox
        let socket = win.webSocket
        // A rejected frame must reset the destination plane, not vanish.
        outbox.onOverflow = { [weak socket] in
            socket?.cancel(with: .abnormalClosure, reason: nil)
        }
        // The loop must not retain `self`, so a dropped plane finishes its outbox.
        self.writer = Task.detached(priority: .userInitiated) {
            while let frame = await outbox.next() {
                do {
                    try await Self.send(frame.data, on: socket)
                } catch {
                    outbox.close(with: error)
                    // Closing the socket makes the receive loop report the plane failure.
                    socket.cancel(with: .abnormalClosure, reason: nil)
                    return
                }
                outbox.complete(frame)
            }
        }
    }

    deinit {
        // Releases queued frames and completes their failure outcomes once.
        outbox.stop()
    }

    /// Stop the writer and fail everything still queued. The caller owns the
    /// socket teardown (receive loop, URLSession invalidation).
    func stop() {
        outbox.stop()
    }

    /// Queued plus in-flight frames and bytes, for diagnostics and tests.
    var outboxDepth: (frames: Int, bytes: Int) { outbox.depth }

    func markReceived() {
        receiveLock.lock()
        lastReceiveDate = Date()
        receiveLock.unlock()
    }

    /// Encrypt one message and queue it behind every frame encrypted before it.
    ///
    /// Throws `PlaneIOError` when the frame is not admitted; such a frame is
    /// neither sent nor counted, and the caller must not report delivery.
    func enqueue(
        _ message: [String: Any],
        compress: Bool,
        onFailure: (@Sendable (Error) -> Void)? = nil
    ) throws {
        let payload = try WireMessage.pack(message, compression: compress)
        let estimate = payload.count + Self.frameOverheadBytes
        cryptoLock.lock()
        defer { cryptoLock.unlock() }
        // Reserve before encrypting: a rejected frame must not consume a counter.
        switch outbox.reserve(bytes: estimate) {
        case .admitted:
            break
        case .overloaded:
            throw PlaneIOError.overloaded
        case .stopped:
            throw PlaneIOError.stopped
        }
        let frame: Data
        do {
            let encrypted = try secureChannel.encrypt(payload)
            frame = try WireFrame.encode(type: WireProtocol.frameData, channelID: channelID, payload: encrypted)
        } catch {
            outbox.cancelReservation(bytes: estimate)
            throw error
        }
        outbox.commit(
            PlaneOutbox.Frame(data: frame, onFailure: onFailure),
            estimatedBytes: estimate
        )
    }

    /// Queue an unencrypted control frame (pong) in the same single writer.
    /// A pong has no requester: if the plane is full or gone it is dropped and
    /// the plane reset path takes over.
    private func enqueueRaw(_ frame: Data) {
        guard case .admitted = outbox.reserve(bytes: frame.count) else { return }
        outbox.commit(
            PlaneOutbox.Frame(data: frame, onFailure: nil),
            estimatedBytes: frame.count
        )
    }

    private static func send(_ frame: Data, on socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotThrowingContinuation(continuation)
            let watchdog = Task.detached {
                try? await Task.sleep(for: .seconds(sendTimeout))
                guard !Task.isCancelled else { return }
                gate.resume(throwing: RemoteClient.ConnectionError.timeout)
            }
            socket.send(.data(frame)) { error in
                watchdog.cancel()
                if let error {
                    gate.resume(throwing: error)
                } else {
                    gate.resume()
                }
            }
        }
    }

    /// WebSocket 协议 ping；收到 pong 视为该平面仍活着。
    ///
    /// `sendPing` 的完成回调在断线竞态下可能触发不止一次；直接 resume
    /// `CheckedContinuation` 会断言闪退，必须走一次性门闩。
    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotThrowingContinuation(continuation)
            webSocket.sendPing { error in
                if let error {
                    gate.resume(throwing: error)
                } else {
                    gate.resume()
                }
            }
        }
        markReceived()
    }

    /// 收一帧并在本对象上解密/解包。Ping 在这里直接回应。无业务消息时返回 nil。
    ///
    /// `@concurrent` is required: with approachable concurrency (SE-0461) a plain
    /// nonisolated async method runs on the caller's actor, and the receive loop is
    /// started from the main actor — decrypt, inflate and JSON parsing of every frame
    /// would otherwise block the UI thread.
    @concurrent
    func pump() async throws -> WireResponseBox? {
        let raw = try await receiveBinary()
        markReceived()
        let (frameType, _, payload) = try WireFrame.decode(raw)
        switch frameType {
        case WireProtocol.frameData:
            let decrypted = try decrypt(payload)
            let message = try WireMessage.unpack(decrypted)
            return WireResponseBox(value: message)
        case WireProtocol.framePing:
            let pong = try WireFrame.encode(type: WireProtocol.framePong, channelID: channelID)
            enqueueRaw(pong)
            return nil
        default:
            return nil
        }
    }

    private func decrypt(_ frame: Data) throws -> Data {
        cryptoLock.lock()
        defer { cryptoLock.unlock() }
        return try secureChannel.decrypt(frame)
    }

    private func receiveBinary() async throws -> Data {
        let message = try await webSocket.receive()
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return Data(text.utf8)
        @unknown default:
            throw RemoteClient.ConnectionError.invalidResponse
        }
    }
}

/// Admission rejection from one plane. Callers map it to "not connected": the
/// frame was not sent and the destination plane is being reset.
nonisolated enum PlaneIOError: Error, Sendable, Equatable {
    case overloaded
    case stopped
}

nonisolated struct WireResponseBox: @unchecked Sendable {
    let value: [String: Any]
    var message: [String: Any] { value }

    init(value: [String: Any]) {
        self.value = value
    }
}
