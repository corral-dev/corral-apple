import Foundation

/// Localized titles for session notifications (waiting / completed / aborted / transient).
///
/// Static keys only. `String(localized: "notification.\(kind)")` with a runtime
/// variable compiles to the single catalog key `notification.%@`, which has no
/// entry — the device then renders the raw `notification.completed` key.
/// Keep every user-visible title as a string literal so `check_localizations.py`
/// and the xcstrings extractor can see it.
nonisolated enum SessionNotificationText {
    static func title(forKind kind: String) -> String? {
        switch kind {
        case "waiting":
            return String(localized: "notification.waiting")
        case "completed":
            return String(localized: "notification.completed")
        case "aborted":
            return String(localized: "notification.aborted")
        case "transient":
            return String(localized: "notification.transient")
        default:
            return nil
        }
    }
}
