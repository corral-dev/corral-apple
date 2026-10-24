#if DEBUG
import AppKit
import Foundation

/// Debug-only prompt jump acceptance (`-CorralInspectPromptJump`, with
/// `-CorralInspectConversation` and `CORRAL_INSPECTION_SESSION_KEY` naming a long
/// session). The pane jumps to its first prompt, the second and the last, each in
/// one unanimated move; each step first writes its name to
/// `/tmp/corral-mac-prompt-jump-step.txt` so an external sampler can capture frames.
///
/// After each jump settles the harness writes the live table's first visible
/// row, the target row's top against the reading viewport top, and app-owned
/// window/pane renders to `/tmp/corral-mac-prompt-jump-<step>.png`. The owner
/// rule is that the selected message is the viewport's top row; the render
/// documents what was actually on screen, the geometry proves the alignment.
@MainActor
enum MacPromptJumpInspection {
    static let stepPath = "/tmp/corral-mac-prompt-jump-step.txt"

    static func run(key: String, workspace: MacWorkspace, prompts: () -> [RichMessage]) async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectPromptJump"),
              ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == key else { return }
        for _ in 0..<40 where prompts().count < 3 {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let list = prompts()
        guard !list.isEmpty else {
            mark("error: no prompts")
            return
        }
        try? await Task.sleep(for: .seconds(4))
        var reports: [[String: Any]] = []
        // A handoff target often has a single human prompt. Keep the long-session
        // three-step sweep, but still verify that one prompt lands on top.
        let steps = list.count >= 3
            ? [("first", list[0]), ("second", list[1]), ("last", list[list.count - 1])]
            : [("first", list[0])]
        for (name, prompt) in steps {
            let target = ConversationTimelineItem.message(prompt).id
            mark(name)
            try? await Task.sleep(for: .milliseconds(400))
            let before = sample(key: key, workspace: workspace)
            workspace.scrollToPrompt(target, in: key)
            var frames: [[String: Double]] = []
            for _ in 0..<75 {
                try? await Task.sleep(for: .milliseconds(8))
                if let frame = sample(key: key, workspace: workspace) { frames.append(frame) }
            }
            try? await Task.sleep(for: .seconds(3))
            var report = record(step: name, target: target, key: key, workspace: workspace)
            report["before"] = before ?? [:]
            report["frames"] = frames
            reports.append(report)
            if let data = try? JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-prompt-jump.json"), options: .atomic)
            }
        }
        mark("done")
    }

    /// Clip origin and conversation opacity of the pane, sampled while a jump
    /// runs: an unanimated jump shows only the start and final offsets at full
    /// opacity, never intermediate positions or a fade.
    private static func sample(key: String, workspace: MacWorkspace) -> [String: Double]? {
        guard let pane = workspace.paneSurfaces.existingEntry(for: key)?.view,
              let table = descendants(pane).compactMap({ $0 as? MacConversationTable.ConversationTableView })
                .max(by: { $0.frame.height < $1.frame.height }),
              let scroll = table.enclosingScrollView else { return nil }
        return ["t": Date.now.timeIntervalSince1970,
                "originY": Double(scroll.contentView.bounds.origin.y),
                "alpha": Double(scroll.alphaValue),
                "layerOpacity": Double(scroll.layer?.presentation()?.opacity ?? scroll.layer?.opacity ?? 1)]
    }

    /// The comparison is against the reading viewport, not the raw clip view:
    /// content scrolls under the pane chrome. `visibleIDs` is published from the
    /// same `readingRect` the jump targets.
    private static func record(step: String, target: String, key: String, workspace: MacWorkspace) -> [String: Any] {
        var result: [String: Any] = ["step": step, "targetID": target]
        guard let pane = workspace.paneSurfaces.existingEntry(for: key)?.view else {
            result["paneMissing"] = true
            return result
        }
        let store = workspace.paneSurfaces.store(for: key)
        if let store, let probe = MacChatScrollGeometryProbe.latest[ObjectIdentifier(store)] {
            let visible = probe["visibleIDs"] as? [String] ?? []
            result["firstVisibleID"] = visible.first ?? ""
            result["visibleIDs"] = visible
            result["targetIsFirstVisible"] = visible.first == target
            result["visibleMinY"] = number(probe["visibleMinY"])
            result["readingMinY"] = number(probe["readingMinY"])
            result["contentHeight"] = number(probe["contentHeight"])
            result["followsLatest"] = probe["followsLatest"]
        } else {
            result["probeMissing"] = true
        }
        let tables = descendants(pane).compactMap { $0 as? MacConversationTable.ConversationTableView }
        if let table = tables.max(by: { $0.frame.height < $1.frame.height }) {
            let range = table.rows(in: table.visibleRect)
            result["tableRows"] = table.numberOfRows
            result["visibleRowRange"] = [range.location, range.length]
            var targetTop: Double?
            if range.location != NSNotFound {
                for index in range.location..<min(table.numberOfRows, range.location + range.length) {
                    guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false)
                        as? MacConversationTable.RowCell else { continue }
                    if index == range.location { result["appKitFirstVisibleID"] = cell.rowID ?? "" }
                    if cell.rowID == target { targetTop = Double(table.rect(ofRow: index).minY) }
                }
            }
            result["targetTop"] = targetTop ?? -1
            if let targetTop, let reading = result["readingMinY"] as? Double {
                result["targetTopMinusReadingTop"] = targetTop - reading
            }
        }
        guard let window = pane.window, let content = window.contentView else {
            result["windowMissing"] = true
            return result
        }
        result["windowCapture"] = capture(content, name: "/tmp/corral-mac-prompt-jump-\(step).png")
        result["paneCapture"] = capture(pane, name: "/tmp/corral-mac-prompt-jump-\(step)-pane.png")
        return result
    }

    /// Window/pane content through `NSView.cacheDisplay`; not a desktop screenshot.
    private static func capture(_ view: NSView, name: String) -> Bool {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: name))) != nil
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func number(_ value: Any?) -> Double {
        switch value {
        case let double as Double: return double
        case let number as NSNumber: return number.doubleValue
        case let cg as CGFloat: return Double(cg)
        default: return -1
        }
    }

    private static func mark(_ step: String) {
        try? step.write(toFile: stepPath, atomically: true, encoding: .utf8)
    }
}
#endif
