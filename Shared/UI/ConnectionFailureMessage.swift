import Foundation

/// The one place connection and pairing surfaces turn errors into user copy.
enum ConnectionFailureMessage {
    static func text(for error: Error) -> String {
        if ConnectionFailureText.copy(for: error) == .keychainUnavailable {
            return String(localized: "connection.keychain_failed")
        }
        return error.localizedDescription
    }
}
