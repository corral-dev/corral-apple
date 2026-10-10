import Foundation

// MARK: - 握手 socket 生命周期与抢答仲裁（可测）

/// 一条握手中 socket 的一次性状态机：open → adopted | closed。
///
/// `adopt()` 与 `close()` 可能被不同任务并发调用（握手完成 vs 取消 / 超时）；
/// 锁保证恰好一方胜出：关掉的 socket 绝不会被当赢家，赢家也绝不会被事后关掉。
nonisolated final class HandshakeSocketLifecycle: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case open
        case adopted
        case closed
    }

    private let lock = NSLock()
    private var phase: Phase = .open
    private var timedOut = false
    private let closeSocket: @Sendable () -> Void

    init(close: @escaping @Sendable () -> Void) {
        closeSocket = close
    }

    var currentPhase: Phase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// 握手成功后由持有者调用；返回 false 表示 socket 已被关掉，本轮按失败处理。
    func adopt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .open else { return false }
        phase = .adopted
        return true
    }

    /// 取消 / 失败：尚未被采纳则关 socket。已采纳的由持有者负责。
    @discardableResult
    func close() -> Bool {
        lock.lock()
        guard phase == .open else {
            lock.unlock()
            return false
        }
        phase = .closed
        lock.unlock()
        closeSocket()
        return true
    }

    /// 单路超时：与 `close()` 相同，另打上超时标记供错误归类。
    func expire() {
        lock.lock()
        let shouldClose = phase == .open
        if shouldClose {
            phase = .closed
            timedOut = true
        }
        lock.unlock()
        if shouldClose { closeSocket() }
    }
}

/// 多路握手仲裁：只等第一个赢家；输家立刻取消并关 socket；迟到赢家也关掉。
///
/// 不用 TaskGroup 是因为 group 退出要等所有子任务结束，而一条连不通地址的
/// receive 可能挂几十秒。这里每路是独立 detached 任务，仲裁只依赖锁保护的状态。
/// 泛型化便于单测（用假 Win 类型），真实使用见 `RemoteClient.raceHandshakes`。
nonisolated final class HandshakeArbiter<Win: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var pendingWinner: Win?
    private var settled = false
    private var launched = 0
    private var finished = 0
    private var lastError: Error?
    private var continuation: CheckedContinuation<Win, Error>?
    private var timeoutTask: Task<Void, Never>?
    private let discard: @Sendable (Win) -> Void

    /// `discard` 负责关掉没人要的赢家（迟到 / 已取消）。
    init(discard: @escaping @Sendable (Win) -> Void) {
        self.discard = discard
    }

    /// 起一路尝试。所有 `launch` 应在 `awaitWinner` 之前同步完成。
    ///
    /// 返回可丢弃的任务句柄，仅供测试观测该路尝试的实际完成：句柄完成即
    /// 该路 `offer`/`fail` 已执行（同一任务内程序顺序 + `await` 同步），天然
    /// happens-before。生产调用方直接丢弃即可；锁流程与取消语义不变。
    /// 返回 nil 仅表示调用瞬间已 settled，本次未注册新尝试。
    @discardableResult
    func launch(_ attempt: @escaping @Sendable () async throws -> Win) -> Task<Void, Never>? {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return nil
        }
        launched += 1
        lock.unlock()
        let task = Task.detached(priority: .userInitiated) { [self] in
            do {
                let win = try await attempt()
                self.offer(win)
            } catch {
                self.fail(error)
            }
        }
        lock.lock()
        if settled {
            lock.unlock()
            task.cancel()
            return task
        }
        tasks.append(task)
        lock.unlock()
        return task
    }

    /// 等第一个赢家；全部失败抛最后一个非取消错误；到点抛 timeout；
    /// 调用方被取消时取消全部尝试并抛 `CancellationError`。
    func awaitWinner(overallTimeout: TimeInterval) async throws -> Win {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Win, Error>) in
                lock.lock()
                if let win = pendingWinner {
                    pendingWinner = nil
                    lock.unlock()
                    cont.resume(returning: win)
                    return
                }
                if settled {
                    let error = lastError ?? CancellationError()
                    lock.unlock()
                    cont.resume(throwing: error)
                    return
                }
                if launched == 0 {
                    settled = true
                    lock.unlock()
                    cont.resume(throwing: RemoteClient.ConnectionError.handshakeFailed("没有可用的连接地址"))
                    return
                }
                continuation = cont
                timeoutTask = Task.detached { [self] in
                    try? await Task.sleep(for: .seconds(overallTimeout))
                    guard !Task.isCancelled else { return }
                    self.timeOut()
                }
                lock.unlock()
            }
        } onCancel: {
            cancelAll()
        }
    }

    // MARK: 仲裁内部

    private func offer(_ win: Win) {
        lock.lock()
        if settled {
            lock.unlock()
            discard(win)
            return
        }
        settled = true
        let others = tasks
        tasks.removeAll()
        let timer = timeoutTask
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        if cont == nil { pendingWinner = win }
        lock.unlock()
        timer?.cancel()
        for task in others { task.cancel() }
        cont?.resume(returning: win)
    }

    private func fail(_ error: Error) {
        lock.lock()
        finished += 1
        if !(error is CancellationError) { lastError = error }
        guard !settled, finished >= launched else {
            lock.unlock()
            return
        }
        settled = true
        let timer = timeoutTask
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        let final = lastError ?? RemoteClient.ConnectionError.handshakeFailed("没有可用的连接地址")
        lock.unlock()
        timer?.cancel()
        cont?.resume(throwing: final)
    }

    private func timeOut() {
        settle(with: RemoteClient.ConnectionError.timeout)
    }

    func cancelAll() {
        settle(with: CancellationError())
    }

    private func settle(with error: Error) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        let others = tasks
        tasks.removeAll()
        let timer = timeoutTask
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        let orphan = pendingWinner
        pendingWinner = nil
        if lastError == nil { lastError = error }
        lock.unlock()
        timer?.cancel()
        for task in others { task.cancel() }
        if let orphan { discard(orphan) }
        cont?.resume(throwing: error)
    }
}
