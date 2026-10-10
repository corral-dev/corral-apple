import Foundation

nonisolated enum HapticEvent: String, Sendable {
    case selection, committed, success, warning, error

    var deduplicationPhase: String {
        switch self {
        case .warning, .error: "attention"
        default: rawValue
        }
    }

    static func failure(for error: Error) -> Self? {
        guard !(error is CancellationError) else { return nil }
        if let url = error as? URLError, url.code == .cancelled { return nil }
        return error is RemoteCallError || error is PairingParseError ? .error : .warning
    }
}

@MainActor
final class HapticScope {
    private var isVisible = false
    private var operations = Set<UUID>()

    func activate() { isVisible = true }
    func deactivate() {
        isVisible = false
        operations.removeAll()
    }
    func beginOperation() -> UUID {
        let id = UUID()
        operations.insert(id)
        return id
    }
    func allows(_ operationID: UUID) -> Bool {
        isVisible && operations.contains(operationID)
    }
}

/// Consumes suppressed events too, so returning to a page never replays them.
nonisolated struct HapticFeedbackPolicy {
    private var consumed = Set<String>()
    private var order: [String] = []
    private var lastSelectionTime: TimeInterval?

    mutating func consume(
        _ event: HapticEvent,
        operationID: UUID,
        isActive: Bool,
        isVisible: Bool,
        now: TimeInterval
    ) -> Bool {
        let key = "\(operationID.uuidString):\(event.deduplicationPhase)"
        guard consumed.insert(key).inserted else { return false }
        order.append(key)
        if order.count > 256 { consumed.remove(order.removeFirst()) }
        guard isActive, isVisible else { return false }
        if event == .selection {
            if let previous = lastSelectionTime, now - previous < 0.15 { return false }
            lastSelectionTime = now
        }
        return true
    }
}
