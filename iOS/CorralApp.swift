#if os(iOS)
import SwiftUI
import UserNotifications

@main
struct CorralApp: App {
    @UIApplicationDelegateAdaptor(CorralAppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()
    @State private var navigationPath = NavigationPath()
    /// Ticket already routed for the pending tap. A new ticket replaces the
    /// notification path with the tapped host; repeats of the routed ticket no-op.
    @State private var routedTicket: UInt64?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Apple requires the notification-center delegate before the app finishes
        // launching; a cold-launch tap response must never arrive before first
        // appear. configure() keeps the idempotent re-set plus categories/status.
        UNUserNotificationCenter.current().delegate = PushRegistrar.shared
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $navigationPath) {
                HostListView()
            }
            .tint(Palette.accent)
            .environment(appModel)
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard arguments.contains("-CorralInspectConversation")
                    || arguments.contains("-CorralInspectLoadEarlier") else { return }
                if appModel.hosts.isEmpty {
                    try? await Task.sleep(for: .milliseconds(400))
                }
                let connectedID = appModel.connectedHostID
                let host = appModel.hosts.first(where: { $0.hostID == connectedID })
                    ?? appModel.hosts.first
                guard let host else { return }
                navigationPath.append(host)
            }
            #if DEBUG
            // Inspection only: lets one installed Debug build be photographed in both
            // appearances. Release builds carry neither the switch nor the override.
            .preferredColorScheme(InspectionLaunchOptions.forcedColorScheme)
            .draftImageInspection()
            .task {
                guard let raw = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PAIR_URL"],
                      let url = URL(string: raw),
                      let payload = try? PairingPayload.parse(url: url) else { return }
                _ = try? await appModel.completePairing(payload, deviceName: "Corral UI Review Simulator")
            }

            .task {
                guard ProcessInfo.processInfo.arguments.contains("-CorralInspectSessions")
                    || ProcessInfo.processInfo.arguments.contains("-CorralInspectNewSession"),
                      let host = appModel.hosts.first else { return }
                navigationPath.append(host)
            }
            #endif
            .onAppear {
                PushRegistrar.shared.configure(appModel: appModel)
                appDelegate.appModel = appModel
                // A cold-launch tap may have stored its request before this view
                // (and its NotificationCenter subscription) existed; route it now
                // instead of waiting for the next event or connection change.
                openPendingNotificationIfReady()
            }
            .onOpenURL { url in
                Task {
                    guard let payload = try? PairingPayload.parse(url: url) else { return }
                    _ = try? await appModel.completePairing(payload, deviceName: UIDeviceName.current)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appModel.handleSceneBecameActive()
                    Task { await PushRegistrar.shared.refreshAuthorizationStatus() }
                    openPendingNotificationIfReady()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .corralPendingNotificationOpen)) { _ in
                openPendingNotificationIfReady()
            }
            .onChange(of: appModel.connectedHostID) { _, _ in
                openPendingNotificationIfReady()
            }
        }
    }

    /// Notification-tap host leg: each new request ticket replaces the navigation
    /// path with the tapped host on paired identity alone, never waiting for a
    /// live connection; repeats of the routed ticket no-op. The explicit body tap
    /// authorizes navigation to that host and session. The session leg is pushed
    /// by the host's list after its snapshot loads; unknown hosts are dropped.
    private func openPendingNotificationIfReady() {
        let registrar = PushRegistrar.shared
        guard let request = registrar.pendingOpen.request else {
            routedTicket = nil
            return
        }
        let ticket = registrar.pendingOpen.ticket
        guard NotificationReply.shouldRouteNotification(ticket: ticket, routedTicket: routedTicket) else {
            return
        }
        guard NotificationReply.routablePendingHost(
            requestHostID: request.hostID,
            pairedHostIDs: appModel.hosts.map(\.hostID)
        ) != nil,
        let host = appModel.hosts.first(where: { $0.hostID == request.hostID }) else {
            registrar.clearPendingOpen(hostID: request.hostID)
            return
        }
        navigationPath = NavigationPath()
        navigationPath.append(host)
        routedTicket = ticket
    }
}

/// 接 APNs 设备令牌回调。
final class CorralAppDelegate: NSObject, UIApplicationDelegate {
    weak var appModel: AppModel?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushRegistrar.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in PushRegistrar.shared.didFailToRegister() }
    }
}
#endif
