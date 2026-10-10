import Foundation

/// Root placeholder policy for the session list. This is the exact branch logic
/// the view renders, kept here (Foundation-only) so the no-silent-empty-screen
/// contract for pending taps is unit covered without UIKit:
///
/// - A pending tap never renders the silent empty screen: a failed lookup or an
///   offline wait shows retry recovery; a connected wait with no error yet shows
///   loading (the direct lookup is in flight or about to run).
/// - A failed direct lookup surfaces its error with retry, over both empty and
///   non-empty lists.
/// - An explicit `not_found` renders the dismissible missing view.
/// - Transport/list failures keep their existing card and never consume the tap.
enum SessionListPlaceholder: Equatable {
    case content
    case loading
    case loadFailed
    case tapError
    case tapMissing
    case empty
}

enum SessionListPlaceholderPolicy {
    nonisolated static func resolve(
        sectionsEmpty: Bool,
        isLoading: Bool,
        connected: Bool,
        pendingTapWaiting: Bool,
        tapMissing: Bool,
        tapError: Bool,
        loadFailed: Bool
    ) -> SessionListPlaceholder {
        guard sectionsEmpty else { return .content }
        if loadFailed { return .loadFailed }
        if tapMissing { return .tapMissing }
        if tapError || (pendingTapWaiting && !connected) { return .tapError }
        if isLoading || pendingTapWaiting { return .loading }
        return .empty
    }
}
