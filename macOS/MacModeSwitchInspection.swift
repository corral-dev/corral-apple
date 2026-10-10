#if DEBUG
import Foundation

/// Debug-only: switches the disposable acceptance session between chat and
/// terminal while its pane keeps focus, then types through window key events
/// and erases them (never submitted). Results go to
/// /tmp/corral-mac-mode-switch.json; each terminal phase holds four seconds
/// so window captures can check for a blank terminal.
@MainActor
enum MacModeSwitchInspection {
    static func run(workspace: MacWorkspace, feed: HostSessionFeed) async {
        guard let key = feed.listStore.windowSessions.first(where: {
            $0.hosted && $0.cwd.contains("corral-phone-acceptance")
        })?.key else { return }
        workspace.open(key, sessions: feed.listStore.windowSessions)
        workspace.setMode(.chat, for: key)
        workspace.focus(key)
        var cycles: [[String: String]] = []
        for cycle in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            let started = Date()
            workspace.setMode(.terminal, for: key)
            let live = await wait {
                guard let view = TerminalHostView.inspectionLatest, view.window != nil else { return false }
                return view.stream?.phase == .live && view.inspectionVisibleRows > 0
            }
            try? await Task.sleep(for: .seconds(1))
            var record: [String: String] = ["cycle": "\(cycle)", "live": "\(live)",
                                            "seconds_to_live": String(format: "%.1f", Date().timeIntervalSince(started))]
            if let view = TerminalHostView.inspectionLatest {
                if let reset = view.inspectionFirstReset {
                    record["seconds_to_snapshot"] = String(format: "%.2f", reset.timeIntervalSince(started))
                }
                record["keyboard_focus"] = "\(view.inspectionHasKeyboardFocus)"
                record["visible_rows"] = "\(view.inspectionVisibleRows)"
                record["font"] = "\(view.inspectionFontSize)"
                record["text"] = view.inspectionVisibleText.filter { !$0.isEmpty }.suffix(4).joined(separator: " | ")
                let marker = "zq\(cycle)x"
                view.inspectionPressKeys(marker.map(String.init))
                record["typed_visible"] = "\(await wait { view.inspectionContains(marker) })"
                view.inspectionPressKeys(Array(repeating: "\u{7f}", count: marker.count))
                record["typed_erased"] = "\(await wait { !view.inspectionContains(marker) })"
            }
            cycles.append(record)
            save(cycles)
            try? await Task.sleep(for: .seconds(3))
            workspace.setMode(.chat, for: key)
        }
        save(cycles)
    }

    private static func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func save(_ cycles: [[String: String]]) {
        if let data = try? JSONSerialization.data(withJSONObject: cycles, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-mode-switch.json"), options: .atomic)
        }
    }
}
#endif
