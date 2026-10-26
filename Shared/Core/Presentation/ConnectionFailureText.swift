import Foundation

/// Which failures must be replaced by their own recovery copy.
///
/// `Security` failures bridge to `NSError` descriptions such as
/// "The operation couldn't be completed. (Corral.HostKeychainError error 1.)";
/// the numeric `OSStatus` is useful in logs but not to a user.
nonisolated enum ConnectionFailureText {
    enum Copy: Sendable, Equatable {
        case keychainUnavailable
    }

    /// `nil` means the error's own description is already user-facing.
    static func copy(for error: Error) -> Copy? {
        error is HostKeychainError ? .keychainUnavailable : nil
    }
}
