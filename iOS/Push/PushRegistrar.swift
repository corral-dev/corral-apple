#if os(iOS)
import Foundation
import UIKit
import UserNotifications

/// APNs registration and push.register upload; notification quick-reply.
///
/// Authorization is on-demand (after pairing / settings), never on cold launch.
@MainActor
final class PushRegistrar: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistrar()

    private weak var appModel: AppModel?
    private var deviceToken: Data?
    /// Mirrored for settings UI; refreshed on configure / request / foreground.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Pending notification-tap open request, consumed by the navigation path.
    private(set) var pendingOpen = PendingNotificationOpen()

    private override init() {
        super.init()
    }

    func configure(appModel: AppModel) {
        self.appModel = appModel
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
        // Replay a tap that arrived before the model attached (cold launch):
        // the request was stored without validation; now validate and connect.
        kickPendingHostConnection()
        Task { await refreshAuthorizationStatus() }
    }

    /// Ask once when undetermined; if already authorized, register for APNs.
    /// Denied: do not re-prompt — caller should offer Open Settings.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined:
            #if DEBUG
            // Inspection launches photograph screens; a system permission alert would cover them.
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-CorralInspect") }) {
                return settings.authorizationStatus
            }
            #endif
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            break
        @unknown default:
            break
        }
        return authorizationStatus
    }

    /// Foreground recheck: if user enabled notifications in Settings, pick up the token.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
            if let client = appModel?.client {
                await registerIfNeeded(client: client)
            }
        default:
            break
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func registerIfNeeded(client: RemoteClient) async {
        guard let token = deviceToken else { return }
        // Environment comes from the actual signature, never the build
        // configuration. Unknown means skip the upload rather than misregister.
        guard let environment = PushEnvironment.current() else {
            CompletionNotificationPreferences.shared.registrationError = String(localized: "settings.notifications.registration_failed")
            return
        }
        let preferences = CompletionNotificationPreferences.shared
        do {
            _ = try await client.call(WireProtocol.mPushRegister, params: [
                "token": token.map { String(format: "%02x", $0) }.joined(),
                "env": environment.rawValue,
                "notify_completed": preferences.completed,
                "notify_aborted": preferences.aborted,
            ])
            preferences.registrationError = nil
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectNotifications") {
                let status = await UNUserNotificationCenter.current().notificationSettings()
                let received = await UNUserNotificationCenter.current().deliveredNotifications()
                var report: [String: Any] = ["registered": true, "environment": environment.rawValue,
                    "completed": preferences.completed, "aborted": preferences.aborted,
                    "authorization": status.authorizationStatus.rawValue, "delivered": received.count]
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-CorralNotificationExpectedSessionKey"),
                   index + 1 < arguments.count {
                    let key = arguments[index + 1]
                    let matching = received.filter { $0.request.content.userInfo["session_key"] as? String == key }
                    report["matchingNotifications"] = matching.count
                    report["acceptanceBodyMatches"] = matching.contains {
                        $0.request.content.body.contains("CORRAL_FINAL_NOTIFICATION_ACCEPTANCE")
                    }
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: AppStorageLocation.appDirectory.appendingPathComponent("notification-inspection.json"), options: .atomic)
                }
            }
            #endif
        } catch {
            preferences.registrationError = String(localized: "settings.notifications.registration_failed")
        }
    }

    private func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY",
            title: String(localized: String.LocalizationValue("composer.send")),
            options: [],
            textInputButtonTitle: String(localized: String.LocalizationValue("composer.send")),
            textInputPlaceholder: String(localized: String.LocalizationValue("composer.placeholder"))
        )
        let category = UNNotificationCategory(
            identifier: "CORRAL_WAITING",
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func didFailToRegister() {
        CompletionNotificationPreferences.shared.registrationError = String(localized: "settings.notifications.registration_failed")
    }

    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken
        Task {
            if let client = appModel?.client {
                await registerIfNeeded(client: client)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let userInfo = response.notification.request.content.userInfo
        let sessionKey = userInfo["session_key"] as? String
        let hostID = userInfo["host_id"] as? String
        let finish = UnsafeCompletion(completionHandler)
        Task { @MainActor in
            defer { finish.call() }
            switch NotificationReply.route(
                actionIdentifier: actionID,
                hostID: hostID,
                sessionKey: sessionKey,
                text: text
            ) {
            case let .reply(hostID, key, text):
                await NotificationReply.send(
                    hostID: hostID,
                    sessionKey: key,
                    text: text,
                    resolveHost: { id in self.appModel?.hosts.first { $0.hostID == id } },
                    isConnected: { self.appModel?.isConnected(to: $0) == true },
                    connect: { await self.appModel?.connect(to: $0) },
                    currentClient: { self.appModel?.client },
                    supportsReceipts: { $0.supportsCommandReceipts },
                    send: { client, params in _ = try await client.call(WireProtocol.mInputText, params: params) }
                )
            case let .open(hostID, key):
                self.handleNotificationOpen(hostID: hostID, sessionKey: key)
            case .ignore:
                return
            }
        }
    }

    /// Navigation-only tap: record the pending request, signal the navigation path,
    /// and kick the connection without awaiting it; the completion handler fires
    /// immediately via the caller's defer. Never emits input.
    private func handleNotificationOpen(hostID: String, sessionKey: String) {
        // Store first, unconditionally: the delegate may fire before configure()
        // attaches the model (cold launch). Paired-host validation and the
        // connection kick are deferred to kickPendingHostConnection(), which runs
        // here and is replayed on every configure().
        pendingOpen.store(hostID: hostID, sessionKey: sessionKey)
        NotificationCenter.default.post(name: .corralPendingNotificationOpen, object: nil)
        kickPendingHostConnection()
    }

    /// Validate the stored request against the paired hosts and kick the
    /// connection. Safe to call before the model attaches (no-op) and on every
    /// configure() (idempotent): an unpaired host stays stored-but-harmless until
    /// the root routing clears it, never navigating or synthesizing input.
    func kickPendingHostConnection() {
        guard let request = pendingOpen.request, let model = appModel,
              NotificationReply.routablePendingHost(
                  requestHostID: request.hostID,
                  pairedHostIDs: model.hosts.map(\.hostID)
              ) != nil,
              let host = model.hosts.first(where: { $0.hostID == request.hostID }) else { return }
        if model.isConnected(to: host) != true {
            Task { await self.appModel?.connect(to: host) }
        }
    }

    /// Session key pending for this host, if the tap named it.
    func pendingSessionKey(for hostID: String) -> String? {
        pendingOpen.sessionKey(for: hostID)
    }

    /// Compare-and-clear at push time; returns true only for the matching request.
    @discardableResult
    func consumePendingOpen(hostID: String, sessionKey: String) -> Bool {
        pendingOpen.consume(hostID: hostID, sessionKey: sessionKey)
    }

    /// Drop the pending request, e.g. when its host is no longer paired.
    func clearPendingOpen(hostID: String) {
        pendingOpen.clear(hostID: hostID)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        #if DEBUG
        let content = notification.request.content
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectNotifications"),
           content.body.contains("CORRAL_FINAL_NOTIFICATION_ACCEPTANCE") {
            let report: [String: Any] = ["sessionKey": content.userInfo["session_key"] as? String ?? "",
                "hostID": content.userInfo["host_id"] as? String ?? "", "acceptanceBodyMatches": true,
                "source": "foregroundNotificationDelegate"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: AppStorageLocation.appDirectory.appendingPathComponent("notification-received.json"), options: .atomic)
            }
        }
        #endif
        completionHandler([.banner, .sound, .list])
    }
}

private nonisolated struct UnsafeCompletion: @unchecked Sendable {
    private let handler: () -> Void
    nonisolated init(_ handler: @escaping () -> Void) { self.handler = handler }
    nonisolated func call() { handler() }
}
#endif
