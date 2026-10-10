import Foundation
import UserNotifications

/// Resolve notification ownership before sending a reply; the current selection is not its destination.
@MainActor
enum NotificationReply {
    static func send<Client: AnyObject>(
        hostID: String?,
        sessionKey: String?,
        text: String,
        resolveHost: (String) -> HostInfo?,
        isConnected: (HostInfo) -> Bool,
        connect: (HostInfo) async -> Void,
        currentClient: () -> Client?,
        supportsReceipts: (Client) -> Bool,
        send: (Client, [String: Any]) async throws -> Void
    ) async {
        guard let hostID, !hostID.isEmpty, let key = sessionKey, !key.isEmpty,
              !text.isEmpty, let host = resolveHost(hostID) else { return }
        if !isConnected(host) {
            await connect(host)
        }
        // A failed connection, removed pairing, or another host selection during await must not reroute the reply.
        guard !Task.isCancelled, resolveHost(hostID) != nil, isConnected(host),
              let client = currentClient() else { return }
        var params: [String: Any] = ["key": key, "text": text, "submit": true]
        if supportsReceipts(client) {
            params["command_id"] = UUID().uuidString
        }
        // An unknown outcome is never retried automatically, since the host may have executed the input.
        _ = try? await send(client, params)
    }

    /// Pure tap-branch decision, separated for unit coverage without UIKit or APNs.
    ///
    /// - REPLY with non-empty text reuses the quick-reply send path (unchanged).
    /// - A normal body tap (`UNNotificationDefaultActionIdentifier`, always empty
    ///   text) opens the notification's host and session without sending input.
    /// - Dismiss/unknown actions and missing identifiers never navigate or send.
    nonisolated static func route(
        actionIdentifier: String,
        hostID: String?,
        sessionKey: String?,
        text: String
    ) -> NotificationTapRoute {
        guard let hostID, !hostID.isEmpty, let key = sessionKey, !key.isEmpty else {
            return .ignore
        }
        if actionIdentifier == "REPLY" {
            return text.isEmpty ? .ignore : .reply(hostID: hostID, sessionKey: key, text: text)
        }
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            return .open(hostID: hostID, sessionKey: key)
        }
        return .ignore
    }
}

/// Tap-branch outcome for `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
enum NotificationTapRoute: Equatable {
    case reply(hostID: String, sessionKey: String, text: String)
    case open(hostID: String, sessionKey: String)
    case ignore
}

/// Tap-resolution outcome for a pending notification open request against the
/// current snapshot. Pure so the no-silent-empty-screen contract is unit covered
/// without UIKit. `sessions.list/watch` is a window (`has_more`), never an
/// authoritative catalog: a missing key waits for a direct `session.get` lookup,
/// and only the server's explicit `not_found` declares the target gone.
enum NotificationTapResolution: Equatable {
    /// Key is in the snapshot: consume the ticket and push the route.
    case push
    /// Key absent: keep the ticket and resolve via direct lookup when connected.
    case wait
    /// Direct lookup answered explicit `not_found`: consume with visible recovery.
    case unavailable
}

/// A single pending notification open request. Consecutive identical taps collapse
/// to one value; consumption is compare-and-clear at push time.
struct NotificationOpenRequest: Equatable {
    let hostID: String
    let sessionKey: String
}

struct PendingNotificationOpen {
    private(set) var request: NotificationOpenRequest?
    /// Bumps only when the stored request actually changes, so rapid identical
    /// taps share one ticket while a later tap after consumption routes again.
    private(set) var ticket: UInt64 = 0

    /// Store a tap request; empty identifiers are ignored, identical repeats collapse.
    mutating func store(hostID: String, sessionKey: String) {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return }
        let next = NotificationOpenRequest(hostID: hostID, sessionKey: sessionKey)
        if request != next {
            request = next
            ticket &+= 1
        }
    }

    func sessionKey(for hostID: String) -> String? {
        guard request?.hostID == hostID else { return nil }
        return request?.sessionKey
    }

    /// Clear only when the pushed route matches; a lost race never clears a newer tap.
    @discardableResult
    mutating func consume(hostID: String, sessionKey: String) -> Bool {
        guard request == NotificationOpenRequest(hostID: hostID, sessionKey: sessionKey) else {
            return false
        }
        request = nil
        return true
    }

    mutating func clear(hostID: String) {
        if request?.hostID == hostID {
            request = nil
        }
    }

    mutating func clearAll() {
        request = nil
    }
}

extension NotificationReply {
    /// A new request ticket replaces the notification navigation path; repeats of
    /// the already-routed ticket are no-ops. Pure so the rule is unit covered.
    nonisolated static func shouldRouteNotification(ticket: UInt64, routedTicket: UInt64?) -> Bool {
        ticket != routedTicket
    }

    /// Resolve a pending tap against the current snapshot. `found` answers whether
    /// the key is in the store. A miss is always `.wait`: list windows (bounded,
    /// `unchanged`, or stale) can never prove absence; only a direct `session.get`
    /// `not_found` may do that.
    nonisolated static func resolveTap(found: Bool) -> NotificationTapResolution {
        found ? .push : .wait
    }

    /// One lookup per ticket: a lookup already in flight for this ticket must not
    /// be started again. A newer ticket always supersedes the in-flight one.
    nonisolated static func shouldStartLookup(ticket: UInt64, inflightTicket: UInt64?) -> Bool {
        inflightTicket != ticket
    }

    /// Cold-launch routability: a tap stores its request before any model exists;
    /// routing proceeds only once the paired host list is known. Returns the
    /// request host when it names a paired host, nil otherwise (stored but
    /// harmless — never navigates, never synthesizes input). This is the exact
    /// policy both the registrar replay and the root routing use.
    nonisolated static func routablePendingHost(
        requestHostID: String?,
        pairedHostIDs: [String]
    ) -> String? {
        guard let requestHostID, !requestHostID.isEmpty,
              pairedHostIDs.contains(requestHostID) else { return nil }
        return requestHostID
    }

    /// Classify a direct-lookup failure exactly as the view does: only the server's
    /// explicit `not_found` ends the tap; every transport error, timeout, or other
    /// server code keeps the ticket retryable.
    nonisolated static func classifyLookupError(_ error: Error) -> NotificationTapResolution {
        if let remote = error as? RemoteCallError, remote.code == WireProtocol.eNotFound {
            return .unavailable
        }
        return .wait
    }
}

extension Notification.Name {
    /// Posted on the main actor whenever a notification tap stores an open request.
    static let corralPendingNotificationOpen = Notification.Name("com.x0c.corral.pendingNotificationOpen")
}
