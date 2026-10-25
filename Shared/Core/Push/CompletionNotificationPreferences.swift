import Foundation
import Observation

/// Device-local policy; every registration reports the current values to the host.
@MainActor @Observable
final class CompletionNotificationPreferences {
    static let shared = CompletionNotificationPreferences()
    static let completedKey = "corral.notifyCompleted"
    static let abortedKey = "corral.notifyAborted"
    static let transientKey = "corral.notifyTransient"
    var completed: Bool { didSet { defaults.set(completed, forKey: Self.completedKey) } }
    var aborted: Bool { didSet { defaults.set(aborted, forKey: Self.abortedKey) } }
    /// Retryable failures the runtime may recover from. Off by default: the
    /// host sends no `transient` push until this is explicitly enabled.
    var transient: Bool { didSet { defaults.set(transient, forKey: Self.transientKey) } }
    var registrationError: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completed = defaults.object(forKey: Self.completedKey) as? Bool ?? true
        aborted = defaults.object(forKey: Self.abortedKey) as? Bool ?? true
        transient = defaults.object(forKey: Self.transientKey) as? Bool ?? false
    }
}
