#if DEBUG
import AppKit
import Foundation

/// Debug-only pane-header acceptance (`-CorralInspectPaneHeader` together with
/// `-CorralInspectConversation` and `CORRAL_INSPECTION_SESSION_KEY`). After the
/// split settles it renders each pane and the window through
/// `NSView.cacheDisplay` (not a desktop screenshot), then moves focus to the
/// next pane and renders again so both header surfaces are documented in one
/// run. `-CorralInspectDark` / `-CorralInspectLight` force the app-level
/// appearance for the capture without changing the system appearance.
///
/// The last focus is restored to the pane that held it on entry, so an
/// existing host session group keeps its recorded focus.
@MainActor
enum MacPaneHeaderInspection {
    static func run(workspace: MacWorkspace) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-CorralInspectPaneHeader") else { return }
        if arguments.contains("-CorralInspectDark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if arguments.contains("-CorralInspectLight") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        // Let the split open, connect and lay out live content.
        try? await Task.sleep(for: .seconds(6))
        let enteredFocus = workspace.focusedKey
        let enteredModes = workspace.paneKeys.map { ($0, workspace.mode(for: $0)) }
        var report: [[String: Any]] = []
        report.append(contentsOf: capture(workspace: workspace, step: "entry"))
        report.append(contentsOf: await inspectRestart(workspace: workspace))
        report.append(contentsOf: await inspectDormantClick(workspace: workspace))
        if workspace.paneKeys.count > 1 {
            let other = workspace.paneKeys.first { $0 != workspace.focusedKey }
            if let other {
                workspace.focus(other)
                // Shortly after the state change: longer settling can hide a
                // header that only follows focus when something else rebuilds
                // the pane (owner report 2026-10-17).
                try? await Task.sleep(for: .milliseconds(300))
                report.append(contentsOf: capture(workspace: workspace, step: "focus-fast"))
                try? await Task.sleep(for: .milliseconds(900))
                report.append(contentsOf: capture(workspace: workspace, step: "other-focus"))
            }
        }
        // Leave the person's persisted pane modes and the group's focus as found.
        for (key, mode) in enteredModes where workspace.mode(for: key) != mode {
            workspace.setMode(mode, for: key)
        }
        if let enteredFocus, workspace.focusedKey != enteredFocus {
            workspace.focus(enteredFocus)
            try? await Task.sleep(for: .milliseconds(800))
        }
        let summary: [String: Any] = [
            "keys": workspace.paneKeys,
            "focused": workspace.focusedKey ?? "",
            "appearance": NSApp.effectiveAppearance.name.rawValue,
            "method": "NSView.cacheDisplay; not a desktop screenshot",
            "captures": report,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pane-header.json"), options: .atomic)
        }
    }

    /// `-CorralInspectRestart`: restart the focused disposable pane through the
    /// production menu handler and capture the cue while it runs, on success and
    /// after it clears. Refuses any session outside a `corral-phone-acceptance` project.
    private static func inspectRestart(workspace: MacWorkspace) async -> [[String: Any]] {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectRestart"),
              let key = workspace.focusedKey,
              workspace.projectPath(of: key).contains("corral-phone-acceptance"),
              let restarts = workspace.restarts else { return [] }
        var results: [[String: Any]] = []
        let started = Date()
        let call = Task { await workspace.restart(key) }
        try? await Task.sleep(for: .milliseconds(150))
        results.append(["step": "restart-phase-150ms", "phase": String(describing: restarts.phase(for: key))])
        results.append(contentsOf: capture(workspace: workspace, step: "restarting"))
        await call.value
        let elapsed = Date().timeIntervalSince(started)
        results.append(["step": "restart-settled", "seconds": elapsed,
                        "phase": String(describing: restarts.phase(for: key)),
                        "actionError": workspace.actionError ?? ""])
        results.append(contentsOf: capture(workspace: workspace, step: "restarted"))
        try? await Task.sleep(for: .seconds(3))
        results.append(["step": "restart-cleared", "phase": String(describing: restarts.phase(for: key))])
        results.append(contentsOf: capture(workspace: workspace, step: "cleared"))
        return results
    }

    /// `-CorralInspectDormantClick` (owner report 2026-11-02): switch the lone
    /// pane to another session through the sidebar's `open`, so the first
    /// stays a retained dormant host in the same slot, then resolve clicks at
    /// the visible pane's centre through production click-to-focus. Focus,
    /// sidebar selection and the header must stay on the shown session.
    /// `CORRAL_INSPECTION_SWITCH_KEY` picks the second session;
    /// `CORRAL_INSPECTION_HOLD_SECONDS` holds the state for a window capture.
    private static func inspectDormantClick(workspace: MacWorkspace) async -> [[String: Any]] {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectDormantClick"),
              let feed = workspace.feed, workspace.paneKeys.count == 1,
              let first = workspace.paneKeys.first else { return [] }
        let sessions = feed.listStore.windowSessions
        guard let second = environment["CORRAL_INSPECTION_SWITCH_KEY"]
                ?? sessions.first(where: { $0.key != first && workspace.layout.group(containing: $0.key) == nil })?.key
        else { return [] }
        workspace.open(second, sessions: sessions, takeKeys: false)
        try? await Task.sleep(for: .seconds(3))
        let dormantFrames = workspace.paneFrames.keys.filter { !workspace.isShownPane($0) }.sorted()
        var resolved: [String] = []
        if let frame = workspace.paneFrames[second] {
            let point = CGPoint(x: frame.midX, y: frame.midY)
            for _ in 0..<40 {
                guard let key = workspace.paneKey(atWindowPoint: point) else { continue }
                workspace.focus(key)
                if !resolved.contains(key) { resolved.append(key) }
            }
        }
        try? await Task.sleep(for: .milliseconds(600))
        var results = capture(workspace: workspace, step: "dormant-click")
        results.append(["step": "dormant-click", "dormant": first, "shown": workspace.paneKeys,
                        "focused": workspace.focusedKey ?? "", "resolved": resolved,
                        "dormantFrames": dormantFrames,
                        "headerFocused": workspace.showsFocus(second)])
        if let hold = environment["CORRAL_INSPECTION_HOLD_SECONDS"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(hold))
        }
        workspace.open(first, sessions: feed.listStore.windowSessions, takeKeys: false)
        return results
    }

    private static func capture(workspace: MacWorkspace, step: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for key in workspace.paneKeys {
            guard let pane = workspace.paneSurfaces.existingEntry(for: key)?.view else { continue }
            let slug = key.replacingOccurrences(of: ":", with: "-")
            var result: [String: Any] = [
                "step": step,
                "key": key,
                "focused": key == workspace.focusedKey,
                "frame": NSStringFromRect(pane.frame),
            ]
            let segments = descendants(pane).compactMap { $0 as? NSSegmentedControl }
            if let control = segments.first {
                result["switchFrame"] = NSStringFromRect(control.convert(control.bounds, to: pane))
                result["selectedSegment"] = control.selectedSegment
                result["controlSize"] = control.controlSize.rawValue
                result["bordered"] = control.cell?.isBordered ?? false
            }
            result["paneCapture"] = render(pane, name: "/tmp/corral-pane-header-\(step)-\(slug).png")
            results.append(result)
        }
        if let window = workspace.paneSurfaces.existingEntry(for: workspace.focusedKey ?? "")?.view.window,
           let content = window.contentView {
            var result: [String: Any] = ["step": step, "window": true]
            result["windowCapture"] = render(content, name: "/tmp/corral-pane-header-\(step)-window.png")
            results.append(result)
        }
        return results
    }

    /// Window/pane content through `NSView.cacheDisplay`; not a desktop screenshot.
    private static func render(_ view: NSView, name: String) -> Bool {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: name))) != nil
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
#endif
