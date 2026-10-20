import Foundation
import Observation

/// Per-session restart feedback shared by every surface that can restart or
/// show a session (iPhone header and composer, Mac pane header and composer).
/// The menu selection begins it synchronously so the cue appears in the same
/// frame; the host round trip only settles it (design: UI KB, restart feedback).
@MainActor
@Observable
final class SessionRestartTracker {
    enum Phase: Equatable {
        case restarting
        case restarted
    }

    private(set) var phases: [String: Phase] = [:]
    @ObservationIgnored private var generations: [String: UInt64] = [:]
    @ObservationIgnored private let confirmationDuration: Duration

    init(confirmationDuration: Duration = .seconds(2)) {
        self.confirmationDuration = confirmationDuration
    }

    func phase(for key: String) -> Phase? { phases[key] }

    func isRestarting(_ key: String) -> Bool { phases[key] == .restarting }

    /// Returns false while a restart of the same session is still in flight.
    @discardableResult
    func begin(_ key: String) -> Bool {
        guard phases[key] != .restarting else { return false }
        generations[key, default: 0] &+= 1
        phases[key] = .restarting
        return true
    }

    /// Success shows a short confirmation in the same slots; failure clears at
    /// once so the caller's own error path owns the message.
    func finish(_ key: String, succeeded: Bool) {
        let generation = generations[key, default: 0] &+ 1
        generations[key] = generation
        guard succeeded else {
            phases[key] = nil
            return
        }
        phases[key] = .restarted
        let duration = confirmationDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.generations[key] == generation else { return }
            self.phases[key] = nil
        }
    }
}
