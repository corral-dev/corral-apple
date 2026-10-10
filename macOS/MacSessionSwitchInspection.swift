#if DEBUG
import AppKit
import Foundation

/// Runs the sidebar's workspace action on read-only ended sessions. It does
/// not drive the pointer, change groups, send input or publish conversation text.
@MainActor
enum MacSessionSwitchInspection {
    static var stores: [String: ConversationStore] = [:]
    static var preparationMs: [String: Double] = [:]
    private static var claimed = false

    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-CorralInspectSessionSwitch")
    }

    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard enabled, !claimed else { return }
        claimed = true
        for _ in 0..<100 where workspace.layout.revision == 0 || feed.listStore.windowSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let original = (workspace.paneKeys, workspace.focusedKey, workspace.showingBoard)
        let sessions = feed.listStore.windowSessions
        let candidates = Array(sessions.filter {
            !$0.live && !$0.hosted && $0.attention == .none
                && workspace.layout.group(containing: $0.key) == nil
                && workspace.mode(for: $0.key) == .chat
        }.prefix(3))
        var measurements: [[String: Any]] = []
        for cycle in 0..<4 {
            for (index, session) in candidates.enumerated() {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                stores[session.key] = nil
                preparationMs[session.key] = nil
                let clock = ContinuousClock()
                let started = clock.now
                let stall = MainThreadStallProbe()
                stall.begin()
                workspace.open(session.key, sessions: sessions, takeKeys: false)
                let selectionMs = milliseconds(started.duration(to: clock.now))
                var visible = false
                for _ in 0..<2000 {
                    if let store = stores[session.key], !store.timelineItems.isEmpty,
                       workspace.paneFrames[session.key] != nil,
                       let content = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible })?.contentView {
                        content.layoutSubtreeIfNeeded()
                        content.displayIfNeeded()
                        visible = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                let displayMs = milliseconds(started.duration(to: clock.now))
                try? await Task.sleep(for: .milliseconds(200))
                var record = stall.end()
                record["cycle"] = cycle
                record["sessionIndex"] = index
                record["selectionMs"] = selectionMs
                record["displayMs"] = displayMs
                record["preparationMs"] = preparationMs[session.key] ?? -1
                record["messages"] = stores[session.key]?.messages.count ?? 0
                record["visible"] = visible
                measurements.append(record)
                save(measurements)
                stores[session.key] = nil
            }
        }
        workspace.inspectionRestoreWorkspace(keys: original.0, focus: original.1, board: original.2)
        save(measurements)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func save(_ measurements: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-session-switch.json"), options: .atomic)
    }
}
#endif
