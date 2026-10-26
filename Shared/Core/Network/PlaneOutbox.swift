import Foundation

/// Admission limits for one physical plane's ordered writer.
///
/// Both limits count queued **and** in-flight frames: a socket that stops
/// accepting writes must not move the backlog from the queue into suspended
/// `send` calls. The byte ceiling admits one legal maximum frame
/// (`WireProtocol.maxFrameBytes`) into an empty queue.
nonisolated struct PlaneOutgoingBudget: Sendable, Equatable {
    let maxQueuedBytes: Int
    let maxQueuedFrames: Int

    init(maxQueuedBytes: Int, maxQueuedFrames: Int) {
        self.maxQueuedBytes = max(0, maxQueuedBytes)
        self.maxQueuedFrames = max(1, maxQueuedFrames)
    }

    /// The Go relay's per-destination queue is 8 MiB plus one in-flight frame;
    /// the client uses the same byte ceiling per plane and a frame count that
    /// covers a burst of ordinary requests without reconnecting on local traffic.
    static let standard = PlaneOutgoingBudget(
        maxQueuedBytes: WireProtocol.maxFrameBytes,
        maxQueuedFrames: 256
    )
}

/// Result of asking a plane to admit one more frame.
nonisolated enum PlaneAdmission: Sendable, Equatable {
    case admitted
    /// The queue is full. The plane has been reset and every queued frame was
    /// failed; the caller must not treat its own frame as delivered.
    case overloaded
    /// The writer is stopped (teardown, replacement or a previous failure).
    case stopped
}

/// Bounded, strictly ordered admission in front of one plane's single writer.
///
/// `PlaneIO` assigns the encryption counter and reserves queue space in one
/// critical section, so an admitted frame can never overtake an earlier one and
/// a rejected frame consumes no counter. Frames are still counted while `send`
/// is suspended and released only when it completes.
nonisolated final class PlaneOutbox: @unchecked Sendable {
    /// One frame and who to tell if it never reaches the socket.
    final class Frame: @unchecked Sendable {
        let data: Data
        let onFailure: (@Sendable (Error) -> Void)?
        /// Guarded by the outbox lock. Also makes the failure outcome exactly-once.
        fileprivate var settled = false

        init(data: Data, onFailure: (@Sendable (Error) -> Void)?) {
            self.data = data
            self.onFailure = onFailure
        }
    }

    let budget: PlaneOutgoingBudget
    /// A full queue resets the destination plane instead of discarding frames
    /// silently: the owner closes the socket so the transport rebinds and
    /// consumers resync. Called at most once.
    var onOverflow: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var pending: [Frame] = []
    private var inFlight: Frame?
    private var queuedBytes = 0
    private var queuedFrames = 0
    /// Space promised to a caller that is still encrypting its frame.
    private var reservedBytes = 0
    private var reservedFrames = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var stopped = false
    private var overflowed = false

    init(budget: PlaneOutgoingBudget = .standard) {
        self.budget = budget
    }

    /// Queued plus in-flight frames and bytes, for diagnostics and tests.
    var depth: (frames: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (queuedFrames, queuedBytes)
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Reserve room for a frame that has not been encoded yet. The caller must
    /// follow with `commit` or `cancelReservation`; callers serialize the
    /// reserve/encrypt/commit sequence with the encryption counter.
    func reserve(bytes: Int) -> PlaneAdmission {
        let cost = max(0, bytes)
        lock.lock()
        if stopped {
            let wasOverloaded = overflowed
            lock.unlock()
            return wasOverloaded ? .overloaded : .stopped
        }
        let fits = queuedBytes + reservedBytes + cost <= budget.maxQueuedBytes
            && queuedFrames + reservedFrames + 1 <= budget.maxQueuedFrames
        guard fits else {
            stopped = true
            overflowed = true
            let frames = takeAllLocked()
            let wake = waiter
            waiter = nil
            lock.unlock()
            wake?.resume()
            for report in frames { report?(RemoteClient.ConnectionError.notConnected) }
            onOverflow?()
            return .overloaded
        }
        reservedBytes += cost
        reservedFrames += 1
        lock.unlock()
        return .admitted
    }

    func cancelReservation(bytes: Int) {
        lock.lock()
        reservedBytes = max(0, reservedBytes - max(0, bytes))
        reservedFrames = max(0, reservedFrames - 1)
        lock.unlock()
    }

    /// Turn a reservation into a queued frame. The estimate must be an upper
    /// bound of `frame.data.count` (it is for `WireFrame` + ChaCha20-Poly1305).
    func commit(_ frame: Frame, estimatedBytes: Int) {
        lock.lock()
        reservedBytes = max(0, reservedBytes - max(0, estimatedBytes))
        reservedFrames = max(0, reservedFrames - 1)
        guard !stopped else {
            let report = frame.settled ? nil : frame.onFailure
            frame.settled = true
            let wake = waiter
            waiter = nil
            lock.unlock()
            wake?.resume()
            report?(RemoteClient.ConnectionError.notConnected)
            return
        }
        queuedBytes += frame.data.count
        queuedFrames += 1
        pending.append(frame)
        let wake = waiter
        waiter = nil
        lock.unlock()
        wake?.resume()
    }

    /// The next frame in counter order; `nil` once the writer is stopped and
    /// every queued frame has been settled.
    func next() async -> Frame? {
        while true {
            switch step() {
            case let .frame(frame): return frame
            case .stopped: return nil
            case .empty: await waitForWork()
            }
        }
    }

    /// A frame reached the socket: release its accounting.
    func complete(_ frame: Frame) {
        lock.lock()
        guard !frame.settled else {
            lock.unlock()
            return
        }
        frame.settled = true
        queuedBytes = max(0, queuedBytes - frame.data.count)
        queuedFrames = max(0, queuedFrames - 1)
        if inFlight === frame { inFlight = nil }
        lock.unlock()
    }

    /// The writer failed: stop admission and fail everything still owned,
    /// including the in-flight frame, exactly once.
    func close(with error: Error) {
        lock.lock()
        stopped = true
        let frames = takeAllLocked()
        let wake = waiter
        waiter = nil
        lock.unlock()
        wake?.resume()
        for report in frames { report?(error) }
    }

    /// Teardown, deinit or connection replacement.
    func stop() {
        close(with: RemoteClient.ConnectionError.notConnected)
    }

    private enum Step {
        case frame(Frame)
        case stopped
        case empty
    }

    private func step() -> Step {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return .stopped }
        guard !pending.isEmpty else { return .empty }
        let frame = pending.removeFirst()
        inFlight = frame
        return .frame(frame)
    }

    private func waitForWork() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            // Re-check under the lock: work may have arrived between `step()` and here.
            if !pending.isEmpty || stopped {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// Empty the queue and hand back the failure handlers of every unsettled
    /// frame. Must be called with the lock held.
    private func takeAllLocked() -> [(@Sendable (Error) -> Void)?] {
        var frames = pending
        if let inFlight { frames.append(inFlight) }
        pending.removeAll()
        inFlight = nil
        queuedBytes = 0
        queuedFrames = 0
        reservedBytes = 0
        reservedFrames = 0
        return frames.map { frame in
            guard !frame.settled else { return nil }
            frame.settled = true
            return frame.onFailure
        }
    }
}
