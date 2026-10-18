import Foundation
import Observation

/// Serial, snapshot-based execution. A transport/host change retires the rest
/// of the batch; successful items are never replayed after a partial failure.
@MainActor @Observable
final class MacSessionBatch {
    enum Action: Equatable { case pin, unpin, stop, delete }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Result {
        var succeeded: Set<String> = []
        var failures: [(key: String, message: String)] = []
    }

    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0

    func run(
        keys: [String], isCurrent: () -> Bool,
        operation: (String) async throws -> Void
    ) async -> Result {
        guard !isRunning else { return Result() }
        var seen: Set<String> = []
        let targets = keys.filter { seen.insert($0).inserted }
        isRunning = true
        completed = 0
        total = targets.count
        defer { isRunning = false }
        var result = Result()
        for (index, key) in targets.enumerated() {
            guard !Task.isCancelled, isCurrent() else {
                let message = String(localized: "error.not_connected")
                result.failures += targets[index...].map { ($0, message) }
                break
            }
            do {
                try await operation(key)
                result.succeeded.insert(key)
            } catch {
                result.failures.append((key, error.localizedDescription))
            }
            completed += 1
        }
        return result
    }
}
