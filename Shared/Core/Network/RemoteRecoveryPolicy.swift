import Foundation

/// Shared classification and capped backoff schedule for self-healing remote
/// operations (terminal attach/resync, session resume, initial snapshot load).
/// Non-recoverable protocol/auth denials stop; transient host-starting, timeout,
/// rate-limit, and transport errors retry with bounded backoff.
enum RemoteRecoveryPolicy {
    enum Disposition: Equatable, Sendable {
        case retryable
        case notFound
        case permanent
    }

    /// Backoff delays (in milliseconds) for consecutive retryable failures,
    /// capped at 5 seconds so self-healing never creates a hot loop.
    static let backoffMilliseconds: [Int] = [400, 800, 1500, 3000, 5000]

    static func backoffDuration(attempt: Int) -> Duration {
        let index = min(max(0, attempt), backoffMilliseconds.count - 1)
        return .milliseconds(backoffMilliseconds[index])
    }

    static func classify(_ error: any Error) -> Disposition {
        if let callError = error as? RemoteCallError {
            switch callError.code {
            case "not_found":
                return .notFound
            case "unauthorized", "usage_error":
                return .permanent
            default:
                return .retryable
            }
        }
        if let connectionError = error as? RemoteClient.ConnectionError {
            switch connectionError {
            case .pairingRequired:
                return .permanent
            case .notConnected, .handshakeFailed, .sendFailed, .timeout, .invalidResponse:
                return .retryable
            }
        }
        return .retryable
    }
}
