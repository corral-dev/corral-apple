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
