#if DEBUG
import AppKit
import UserNotifications

/// Inspect the real system center without private databases or driving native controls.
@MainActor enum MacNotificationInspection {
    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        let notifications = MacNotifications.shared
        if ProcessInfo.processInfo.arguments.contains("-CorralNotificationPreviewOnly") {
            await inspectPreview(notifications: notifications, feed: feed)
            return
        }
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

    private static func inspectPreview(notifications: MacNotifications, feed: HostSessionFeed) async {
        let source = "已发布 **[0.3.24 / 3042](https://github.com/NeatMacApps/NeatWebApp/releases/tag/v0.3.24)**。\r\n\r\n- 覆盖安装到本机。\n- 验证 `Error 429`。\n\n```text\nready\t\tok\n```"
        let session = SessionSummary(key: "notification-preview-inspection", title: "Notification preview",
            lastAgent: source, completionID: UUID().uuidString)
        let center = UNUserNotificationCenter.current()
        let notificationID = SessionNotificationKind.completed.identity(hostID: feed.host.hostID, session: session)
        await notifications.deliver(session, kind: "completed", hostID: feed.host.hostID)
        var matching: [UNNotification] = []
        // System processing can outlast enqueue completion; await this exact request.
        for _ in 0..<60 {
            matching = await center.deliveredNotifications().filter { $0.request.identifier == notificationID }
            if !matching.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let report: [String: Any] = ["source": source, "bodies": matching.map { $0.request.content.body },
            "enabled": notifications.enabled, "authorization": notifications.authorization.rawValue,
            "failure": notifications.failure as Any? ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-notification-preview.json"), options: .atomic)
        }
        // Keep the observed notification briefly for an unattended window capture.
        try? await Task.sleep(for: .seconds(10))
        center.removeDeliveredNotifications(withIdentifiers: matching.map { $0.request.identifier })
    }
}
#endif
