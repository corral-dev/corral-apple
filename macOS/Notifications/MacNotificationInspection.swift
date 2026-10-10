#if DEBUG
import AppKit
import UserNotifications

/// Inspect the real system center without private databases or driving native controls.
@MainActor enum MacNotificationInspection {
    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        let notifications = MacNotifications.shared
        await notifications.setEnabled(true)
        let center = UNUserNotificationCenter.current()
        var report: [String: Any] = ["authorization": notifications.authorization.rawValue,
                                    "enabled": notifications.enabled, "hostConnected": feed.isActive]
        report["deliveredBefore"] = await center.deliveredNotifications().count
        if let session = feed.listStore.windowSessions.first(where: { !$0.completionID.isEmpty && $0.status == "✅已完成" }) {
            await notifications.deliver(session, kind: "completed", hostID: feed.host.hostID)
            await notifications.deliver(session, kind: "completed", hostID: feed.host.hostID)
            try? await Task.sleep(for: .seconds(2))
            let after = await center.deliveredNotifications()
            report["deliveredAfter"] = after.count
            await notifications.open(hostID: feed.host.hostID, key: session.key)
            await notifications.resolvePending(feed: feed, workspace: workspace)
            report["navigationMatches"] = workspace.focusedKey == session.key
            report["pendingConsumed"] = notifications.pendingOpen.request == nil
            report["matchingNotifications"] = after.filter {
                $0.request.content.userInfo["session_key"] as? String == session.key
            }.count
        }
        report["failure"] = notifications.failure as Any? ?? NSNull()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-notifications.json"), options: .atomic)
        }
    }
}
#endif
