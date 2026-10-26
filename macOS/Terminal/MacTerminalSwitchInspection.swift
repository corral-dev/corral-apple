#if DEBUG
import AppKit
import Foundation

/// Owner scenario (2026-10-25): switching among running agents shown as TUIs
/// must reveal each terminal's current screen at once, never reattach or show
/// Connecting, even after its warm pane was released. Uses real hosted
/// sessions in memory only (modes are not persisted during inspections) and
/// never sends input to them. `CORRAL_INSPECTION_SHELL_FOLDER` adds a wheel
/// check in a disposable project shell, the only place it types.
@MainActor
enum MacTerminalSwitchInspection {
    static func run(workspace: MacWorkspace, appModel: AppModel, feed: HostSessionFeed) async {
        for _ in 0..<120 where appModel.connectionState != .connected || feed.listStore.windowSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
        let originalKeys = workspace.paneKeys
        let originalFocus = workspace.focusedKey
        defer { workspace.inspectionRestoreWorkspace(keys: originalKeys, focus: originalFocus) }
        let count = Int(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SWITCH_SESSIONS"] ?? "") ?? 3
        let sessions = Array(feed.listStore.windowSessions.filter { $0.hosted && $0.live }.prefix(max(2, count)))
        guard sessions.count >= 2 else {
            write(["error": "fewer than two running hosted sessions"])
            return
        }
        var result: [String: Any] = ["sessions": sessions.map(\.key)]

        // Open each in terminal view once (the honest cold attach).
        var firstViews: [String: ObjectIdentifier] = [:]
        var firstStreams: [String: ObjectIdentifier] = [:]
        var coldMs: [Double] = []
        let clock = ContinuousClock()
        for session in sessions {
            workspace.setMode(.terminal, for: session.key)
            let start = clock.now
            workspace.inspectionRestoreWorkspace(keys: [session.key], focus: session.key)
            _ = await waitUntil(seconds: 10) {
                guard let terminal = workspace.terminals.terminal(for: session.key, client: appModel.client) else { return false }
                return terminal.stream.phase == .live && terminal.view.isShown && terminal.view.hasScreen
            }
            coldMs.append(milliseconds(start.duration(to: clock.now)))
            if let terminal = workspace.terminals.terminal(for: session.key, client: appModel.client) {
                firstViews[session.key] = ObjectIdentifier(terminal.view)
                firstStreams[session.key] = ObjectIdentifier(terminal.stream)
            }
        }
        result["coldOpenMs"] = coldMs

        // Warm switches, releasing every dormant pane surface before each one.
        let attachesBefore = RemoteTerminalStream.inspectionAttachCalls
        var reveals: [[String: Any]] = []
        let environment = ProcessInfo.processInfo.environment
        let rounds = Int(environment["CORRAL_INSPECTION_SWITCH_ROUNDS"] ?? "") ?? 4
        let purges = environment["CORRAL_INSPECTION_SWITCH_PURGE"] != "0"
        for round in 0..<rounds {
            for session in sessions {
                if purges, round.isMultiple(of: 2) { ClientMemoryPressure.purge() }
                let probe = MainThreadStallProbe()
                probe.begin()
                let start = clock.now
                workspace.inspectionRestoreWorkspace(keys: [session.key], focus: session.key)
                let shown = await waitUntil(seconds: 2) {
                    workspace.terminals.terminal(for: session.key, client: appModel.client)?.view.isShown == true
                }
                let revealMs = milliseconds(start.duration(to: clock.now))
                guard let terminal = workspace.terminals.terminal(for: session.key, client: appModel.client) else {
                    reveals.append(["key": session.key, "terminal": false])
                    continue
                }
                let phase = terminal.stream.phase
                let waiting = phase == .connecting && !terminal.view.hasScreen
                try? await Task.sleep(for: .milliseconds(150))
                reveals.append([
                    "key": session.key,
                    "round": round,
                    "shown": shown,
                    "revealMs": revealMs,
                    "phaseAtReveal": String(describing: phase),
                    "waitingIndicator": waiting,
                    "sameView": firstViews[session.key] == ObjectIdentifier(terminal.view),
                    "sameStream": firstStreams[session.key] == ObjectIdentifier(terminal.stream),
                    "visibleRows": terminal.view.inspectionVisibleRows,
                    "maxMainStallMs": probe.end()["maxMainStallMs"] as? Int ?? -1,
                ])
            }
        }
        result["reveals"] = reveals
        result["attachesDuringWarmSwitches"] = RemoteTerminalStream.inspectionAttachCalls - attachesBefore
        result["liveTerminals"] = workspace.terminals.inspectionCount
        if let last = sessions.last, let terminal = workspace.terminals.terminal(for: last.key, client: appModel.client) {
            result["captured"] = capture(terminal.view, name: "reveal")
        }
        result["wheel"] = await inspectWheel(workspace: workspace, appModel: appModel)
        write(result)
    }

    /// Mouse tracking on in a disposable shell, then `cat -v` echoes the
    /// reports SwiftTerm's own wheel handler produced.
    private static func inspectWheel(workspace: MacWorkspace, appModel: AppModel) async -> [String: Any] {
        guard let folder = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SHELL_FOLDER"] else {
            return ["skipped": "no disposable shell folder"]
        }
        let before = Set(workspace.paneKeys)
        await workspace.newTerminal(project: folder)
        guard let key = workspace.paneKeys.first(where: { ProjectShell.isShellKey($0) && !before.contains($0) }) else {
            return ["error": "shell did not open"]
        }
        defer { workspace.endTerminal(key) }
        let ready = await waitUntil(seconds: 10) {
            guard let terminal = workspace.terminals.terminal(for: key, client: appModel.client) else { return false }
            return terminal.stream.phase == .live && terminal.view.isShown
        }
        guard ready, let terminal = workspace.terminals.terminal(for: key, client: appModel.client) else {
            return ["error": "shell terminal not live"]
        }
        try? await Task.sleep(for: .seconds(1))
        terminal.stream.input.send(ArraySlice(Array("printf '\\033[?1000h\\033[?1006h'; cat -v\r".utf8)))
        try? await Task.sleep(for: .seconds(2))
        let up = terminal.view.inspectionScrollWheel(lines: 3)
        let down = terminal.view.inspectionScrollWheel(lines: -3)
        try? await Task.sleep(for: .seconds(2))
        let text = terminal.view.inspectionVisibleText.joined(separator: "\n")
        let echoed = text.components(separatedBy: "^[[<").count - 1
        terminal.stream.input.send(ArraySlice([0x03]))
        try? await Task.sleep(for: .milliseconds(300))
        terminal.stream.input.send(ArraySlice(Array("printf '\\033[?1000l\\033[?1006l'\r".utf8)))
        try? await Task.sleep(for: .milliseconds(500))
        return ["eventsHandled": up && down, "reportsEchoed": echoed,
                "wheelUp": text.contains("^[[<64;"), "wheelDown": text.contains("^[[<65;")]
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    /// Window content through `NSView.cacheDisplay`; not a desktop screenshot.
    private static func capture(_ view: NSView, name: String) -> Bool {
        guard let content = view.window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: "/tmp/corral-terminal-switch-\(name).png"))) != nil
    }

    private static func write(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-terminal-switch.json"), options: .atomic)
    }
}
#endif
