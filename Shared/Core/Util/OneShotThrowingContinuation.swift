import Foundation

/// Bridges a completion-handler API into async/await when the system may fire
/// the callback more than once (notably `URLSessionWebSocketTask.sendPing`).
/// Only the first resume wins; later calls are ignored.
nonisolated final class OneShotThrowingContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

extension OneShotThrowingContinuation where T == Void {
    nonisolated func resume() {
        resume(returning: ())
    }
}
