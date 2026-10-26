#if DEBUG
import AppKit
import Foundation

/// Owner report (2026-10-26): a Pi terminal scrolled back a few rows jumped to
/// the conversation's first line after Pi's full redraw (ED 3 plus the whole
/// transcript). Uses one real hosted Pi session in memory only and never types
/// into it: a claimed one-column resize makes Pi redraw through the real host
/// stream, then the pane's own grid is claimed back (a second redraw).
/// `CORRAL_INSPECTION_PI_SHORT_ID` picks an idle session; the result is written
/// to `/tmp/corral-pi-redraw.json`.
@MainActor
enum MacPiRedrawInspection {
    static func run(workspace: MacWorkspace, appModel: AppModel, feed: HostSessionFeed) async {
        for _ in 0..<120 where appModel.connectionState != .connected || feed.listStore.windowSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
        let originalKeys = workspace.paneKeys
        let originalFocus = workspace.focusedKey
        defer { workspace.inspectionRestoreWorkspace(keys: originalKeys, focus: originalFocus) }
        let wanted = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PI_SHORT_ID"]
        guard let session = feed.listStore.windowSessions.first(where: {
            $0.runtime == "pi" && $0.hosted && $0.live && (wanted == nil || $0.shortID == wanted)
        }) else {
            write(["error": "no running hosted Pi session"])
            return
        }
        workspace.setMode(.terminal, for: session.key)
        workspace.inspectionRestoreWorkspace(keys: [session.key], focus: session.key)
        let ready = await waitUntil(seconds: 15) {
            guard let terminal = workspace.terminals.terminal(for: session.key, client: appModel.client) else { return false }
            return terminal.stream.phase == .live && terminal.view.isShown && terminal.view.hasScreen
        }
        guard ready, let terminal = workspace.terminals.terminal(for: session.key, client: appModel.client),
              let grid = terminal.view.inspectionGrid else {
            write(["error": "Pi terminal not live", "key": session.key])
            return
        }
        try? await Task.sleep(for: .seconds(2))
        var result: [String: Any] = ["key": session.key, "grid": "\(grid.cols)x\(grid.rows)"]
        var steps: [[String: Any]] = []
        for (label, next) in [("narrowed", TerminalGrid(cols: grid.cols - 1, rows: grid.rows)), ("restored", grid)] {
            terminal.view.inspectionScrollUp(lines: 5)
            let readerTop = terminal.view.inspectionVisibleText.first ?? ""
            let readerPosition = terminal.view.inspectionScrollPosition
            let bytes = StreamTerminalView.feedBytes
            terminal.stream.updateFit(next)
            terminal.stream.claimSize()
            var lowest = 1.0
            var timeline: [String] = []
            let start = ContinuousClock.now
            let deadline = start + .seconds(5)
            var last = readerPosition
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                let position = terminal.view.inspectionScrollPosition
                lowest = min(lowest, position)
                if position != last {
                    let ms = Int(start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
                        + Int(start.duration(to: .now).components.seconds) * 1000
                    timeline.append(String(format: "%dms %.3f %@", ms, position,
                                           terminal.view.inspectionGrid.map { "\($0.cols)x\($0.rows)" } ?? ""))
                    last = position
                }
            }
            steps.append([
                "step": label,
                "readerPosition": readerPosition,
                "readerTop": readerTop,
                "bytesFed": StreamTerminalView.feedBytes - bytes,
                "lowestPositionAfterRedraw": lowest,
                "positionTimeline": timeline,
                "finalPosition": terminal.view.inspectionScrollPosition,
                "finalGrid": terminal.view.inspectionGrid.map { "\($0.cols)x\($0.rows)" } ?? "",
                "finalTop": terminal.view.inspectionVisibleText.first ?? "",
                "finalBottomRows": Array(terminal.view.inspectionVisibleText.suffix(4)),
                "captured": capture(terminal.view, name: label),
            ])
        }
        result["steps"] = steps
        write(result)
        // `CORRAL_INSPECTION_PI_HOLD` seconds keep the result on screen for a window capture.
        let hold = Int(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PI_HOLD"] ?? "") ?? 0
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Window content through `NSView.cacheDisplay`; not a desktop screenshot.
    private static func capture(_ view: NSView, name: String) -> Bool {
        guard let content = view.window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pi-redraw-\(name).png"))) != nil
    }

    private static func write(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pi-redraw.json"), options: .atomic)
    }
}
#endif
