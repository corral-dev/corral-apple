import Foundation

/// Debug-only gate for the reserved-pane inspection: while held, the creation
/// coordinator's first host call waits, so the reserved pane is observable on
/// the real window before the session exists. Compiled out of Release.
@MainActor
enum PendingPaneInspectionGate {
    static var hold = false
    private static var continuations: [CheckedContinuation<Void, Never>] = []

    static func waitIfHeld() async {
        guard hold else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    static func resume() {
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}
