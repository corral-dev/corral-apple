#if DEBUG
import AppKit
import SwiftUI

/// Debug-only reserved-pane acceptance (`-CorralInspectPendingPane`).
///
/// Runs on the real window without driving the pointer: opens two ended
/// sessions as a split, then creates a third session through the production
/// `newSessionPane` path. Creation is held open by the debug gate so the
/// reserved pane is observable, then released and the same slot is checked
/// for in-place promotion. Writes `/tmp/corral-pending-pane.json` and renders
/// the window at each step through `NSView.cacheDisplay`.
@MainActor
enum MacPendingPaneInspection {
    static let resultPath = "/tmp/corral-pending-pane.json"

    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        let sessions = feed.listStore.windowSessions
        let ended = sessions.filter { !$0.live && workspace.layout.group(containing: $0.key) == nil }
        guard ended.count >= 2, let runtime = workspace.runtimes.first(where: { $0.isUsable && $0.isActive }) else {
            write(["error": "needs two ended sessions outside groups and one usable runtime"])
            return
        }
        let a = ended[0], b = ended[1]
        // A third pane must fit: the saved window may be too narrow, in which
        // case the reserved pane is drawn beyond the right edge and the
        // capture would look like nothing happened.
        for window in NSApp.windows where window.contentView != nil {
            window.setContentSize(NSSize(width: max(window.frame.width, 2400),
                                         height: max(window.frame.height, 1200)))
            window.setFrameOrigin(NSPoint(x: 40, y: 60))
            window.orderFront(nil)
        }
        try? await Task.sleep(for: .milliseconds(600))
        var steps: [[String: Any]] = []
        var creationStart: Date?
        var reservedMs: Int?
        func record(_ name: String) {
            steps.append([
                "step": name,
                "keys": workspace.paneKeys,
                "pending": Array(workspace.pendingPanes.keys),
                "focused": workspace.focusedKey ?? "none",
            ])
            render(workspace: workspace, name: name)
        }

        workspace.open(a.key, sessions: sessions, takeKeys: true)
        workspace.addPane(b.key, project: b.cwd)
        try? await Task.sleep(for: .seconds(2))
        record("before")

        // Hold the creation RPC: without the gate the whole transition is one
        // frame and there would be nothing to inspect.
        PendingPaneInspectionGate.hold = true
        creationStart = Date()
        let creation = Task { await workspace.newSessionPane(runtimeID: runtime.id) }
        var pendingKey: String?
        for _ in 0..<200 {
            if let key = workspace.paneKeys.first(where: { MacWorkspace.PendingPane.isPending($0) }) {
                pendingKey = key
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        if let creationStart { reservedMs = Int(Date().timeIntervalSince(creationStart) * 1000) }
        record("reserved")
        // Leave the reserved pane on screen long enough for an external window
        // capture of the real surface, then continue.
        let holdSeconds = Double(
            ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PENDING_HOLD"] ?? ""
        ) ?? 6
        try? await Task.sleep(for: .seconds(max(0, min(holdSeconds, 20))))
        let pendingIndex = pendingKey.flatMap { workspace.paneKeys.firstIndex(of: $0) }

        PendingPaneInspectionGate.hold = false
        PendingPaneInspectionGate.resume()
        await creation.value
        try? await Task.sleep(for: .seconds(2))
        record("promoted")
        // Second creation, ungated: the real production latency on this host.
        let secondStart = Date()
        await workspace.newSessionPane(runtimeID: runtime.id)
        let secondElapsedMs = Int(Date().timeIntervalSince(secondStart) * 1000)
        try? await Task.sleep(for: .seconds(1))
        record("second-created")
        let promotedIndex = pendingKey.flatMap { _ in
            workspace.paneKeys.firstIndex(where: { !MacWorkspace.PendingPane.isPending($0) && $0 != a.key && $0 != b.key })
        }

        var windows: [[String: Any]] = []
        for window in NSApp.windows where window.contentView != nil {
            var entry: [String: Any] = ["frame": NSStringFromRect(window.frame), "title": window.title]
            entry["hosts_a"] = workspace.paneSurfaces.existingEntry(for: a.key)?.view.window === window
            entry["hosts_reserved"] = workspace.pendingPanes.keys.contains {
                MacPaneReorderHandles.views[$0]?.window === window
            }
            windows.append(entry)
        }
        write([
            "windows": windows,
            "a": a.key, "b": b.key,
            "runtime": runtime.id,
            "pending_key": pendingKey ?? "none",
            "pending_slot": pendingIndex ?? -1,
            "promoted_slot": promotedIndex ?? -1,
            "promoted_in_place": pendingIndex != nil && pendingIndex == promotedIndex,
            "pending_cleared": workspace.pendingPanes.isEmpty,
            "reserved_ms": reservedMs ?? -1,
            "ungated_creation_ms": secondElapsedMs,
            "steps": steps,
        ])

        // Close the created pane again so the group it formed dissolves.
        if let createdKey = workspace.paneKeys.first(where: { $0 != a.key && $0 != b.key }) {
            workspace.closePane(createdKey)
        }
        workspace.closePane(b.key)
        workspace.closePane(a.key)
    }

    private static func render(workspace: MacWorkspace, name: String) {
        // Render the window that hosts the reserved pane's own SwiftUI header
        // (located through the reorder-handle reader). Falling back to any pane
        // view would pick another Corral window on this machine, which shows the
        // same sessions but not this run's reserved pane.
        let pendingWindow = workspace.pendingPanes.keys.compactMap {
            MacPaneReorderHandles.views[$0]?.window
        }.first
        let candidateWindows: [NSWindow] = [pendingWindow].compactMap { $0 } + workspace.paneKeys.compactMap {
            workspace.paneSurfaces.existingEntry(for: $0)?.view.window
        } + workspace.paneKeys.compactMap { MacPaneReorderHandles.views[$0]?.window }
        guard let window = candidateWindows.first, let content = window.contentView else { return }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pending-pane-\(name).png"))
    }

    private static func write(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: resultPath))
    }
}

#endif
