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

    /// Skip the forced full-subtree layout/draw: measures the window's natural
    /// next-frame work for visible rows only (user-perceived), not the worst
    /// case of realizing every retained row.
    static var noForce: Bool {
        ProcessInfo.processInfo.arguments.contains("-CorralInspectSessionSwitchNoForce")
    }

    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard enabled, !claimed else { return }
        claimed = true
        for _ in 0..<100 where workspace.layout.revision == 0 || feed.listStore.windowSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let original = (workspace.paneKeys, workspace.focusedKey)
        let sessions = feed.listStore.windowSessions
        let candidates = Array(sessions.filter {
            !$0.live && !$0.hosted && $0.attention == .none
                && workspace.layout.group(containing: $0.key) == nil
                && workspace.mode(for: $0.key) == .chat
        }.prefix(8))
        var measurements: [[String: Any]] = []
        for count in [1, 2, 4] where candidates.count >= count * 2 {
          for cycle in 0..<4 {
            for index in 0..<2 {
                let chosen = Array(candidates.dropFirst(index * count).prefix(count))
                guard let session = chosen.first else { continue }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                for session in chosen {
                    stores[session.key] = nil
                    preparationMs[session.key] = nil
                }
                ConversationStore.resetSwitchCounters()
                MacTextRowSwitchCounters.reset()
                SwitchBodyCounters.reset()
                let clock = ContinuousClock()
                let started = clock.now
                let stall = MainThreadStallProbe()
                stall.begin()
                if count == 1 {
                    workspace.open(session.key, sessions: sessions, takeKeys: false)
                } else {
                    // The same split presentation mutation without writing a
                    // temporary group into the host or the user's TUI.
                    workspace.inspectionRestoreWorkspace(keys: chosen.map(\.key), focus: session.key)
                }
                let selectionMs = milliseconds(started.duration(to: clock.now))
                var visible = false
                var firstVisibleMs = -1.0
                for _ in 0..<2000 {
                    if chosen.allSatisfy({ session in
                        let store = workspace.paneSurfaces.store(for: session.key) ?? stores[session.key]
                        return store?.timelineItems.isEmpty == false
                            && (workspace.paneFrames[session.key] != nil || workspace.paneSurfaces.isMounted(session.key))
                    }),
                       let content = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible })?.contentView {
                        // First paint gate (user-perceived): state is ready and the
                        // window will draw visible rows on its next frame. The
                        // forced full layout below measures the worst case, not
                        // what the next display link actually draws.
                        firstVisibleMs = milliseconds(started.duration(to: clock.now))
                        if !noForce {
                            content.layoutSubtreeIfNeeded()
                            content.displayIfNeeded()
                        }
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
                record["panes"] = count
                record["selectionMs"] = selectionMs
                record["firstVisibleMs"] = firstVisibleMs
                record["displayMs"] = displayMs
                record["preparationMs"] = preparationMs[session.key] ?? -1
                record["messages"] = chosen.reduce(0) {
                    $0 + ((workspace.paneSurfaces.store(for: $1.key) ?? stores[$1.key])?.messages.count ?? 0)
                }
                record["visible"] = visible
                record["rowMakes"] = MacTextRowSwitchCounters.makes
                record["rowDismantles"] = MacTextRowSwitchCounters.dismantles
                record["rowTextSets"] = MacTextRowSwitchCounters.textSets
                record["docEarlyReturns"] = MacTextRowSwitchCounters.docEarlyReturns
                record["docRenders"] = MacTextRowSwitchCounters.docRenders
                record["timelineRebuilds"] = ConversationStore.timelineRebuilds
                record["timelineSkips"] = ConversationStore.timelineSkips
                record["promptsHits"] = ConversationStore.promptsHits
                record["promptsRecomputes"] = ConversationStore.promptsRecomputes
                record["bubbleBodies"] = SwitchBodyCounters.bubbleBodies
                record["toolBodies"] = SwitchBodyCounters.toolBodies
                measurements.append(record)
                save(measurements)
                for session in chosen { stores[session.key] = nil }
            }
          }
        }
        workspace.inspectionRestoreWorkspace(keys: original.0, focus: original.1)
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
