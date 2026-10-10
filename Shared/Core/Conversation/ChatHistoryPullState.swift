import Foundation

/// Tracks only direct finger movement; spring-back cannot arm or cancel a pull.
nonisolated struct ChatHistoryPullState {
    static let threshold: Double = 80
    private(set) var isInteracting = false
    private(set) var progress: Double?

    mutating func begin() {
        isInteracting = true
        progress = nil
    }

    mutating func update(distance: Double) {
        guard isInteracting else { return }
        progress = distance.isFinite && distance > 0
            ? min(1, distance / Self.threshold) : nil
    }

    mutating func release() -> Bool {
        let shouldLoad = isInteracting && progress == 1
        reset()
        return shouldLoad
    }

    mutating func reset() {
        isInteracting = false
        progress = nil
    }
}
