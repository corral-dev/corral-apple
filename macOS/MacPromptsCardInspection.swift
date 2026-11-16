#if DEBUG
import AppKit
import Foundation

/// Debug-only acceptance for the prompts card's per-session state
/// (`-CorralInspectPromptsCard`), run on the real window without driving the
/// pointer or keyboard. Opens both split panes' cards, presses one card's real
/// collapse button through accessibility and checks that only that session's
/// choice changed, then closes and reopens that pane to verify the session
/// remembers its collapsed card. Writes `/tmp/corral-mac-prompts-card.json`
/// (override with `CORRAL_INSPECTION_PROMPTS_OUTPUT`).
@MainActor
enum MacPromptsCardInspection {
    private static var claimed = false

    static func start(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard !claimed,
              ProcessInfo.processInfo.arguments.contains("-CorralInspectPromptsCard") else { return }
        claimed = true
        let path = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PROMPTS_OUTPUT"]
            ?? "/tmp/corral-mac-prompts-card.json"
        var report: [String: Any] = ["phase": "waiting"]
        func save(_ phase: String) {
            report["phase"] = phase
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        save("waiting")

        // Two chat panes whose prompts have arrived (the layout and the host
        // history are asynchronous; the card only exists with prompts). An
        // explicit key pair wins; otherwise open two ended sessions outside
        // groups, like the interaction probe, and dissolve that group on exit.
        let sessions = feed.listStore.windowSessions
        let requested = (ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] ?? "")
            .split(separator: ",").map(String.init)
        // Start from an empty local workspace so a restored 3- or 4-pane
        // layout cannot add untracked cards to this two-pane probe. This does
        // not write the host's shared groups.
        workspace.inspectionRestoreWorkspace(keys: [], focus: nil)
        try? await Task.sleep(for: .milliseconds(500))
        if requested.count >= 2 {
            workspace.open(requested[0], sessions: sessions, takeKeys: true)
            for key in requested.dropFirst() { workspace.addPane(key, project: feed.listStore.session(for: key)?.cwd ?? "") }
        } else {
            // Splits keep one project, so pair two ended sessions that share
            // a workspace (the split project contract).
            let ended = sessions.filter { !$0.live }
            var pair: (SessionSummary, SessionSummary)?
            for first in ended {
                if let partner = ended.first(where: { $0.key != first.key && $0.cwd == first.cwd }) {
                    pair = (first, partner)
                    break
                }
            }
            guard let pair else {
                report["error"] = "needs two ended sessions of one project"
                save("needs-two-sessions")
                return
            }
            workspace.open(pair.0.key, sessions: sessions, takeKeys: true)
            workspace.addPane(pair.1.key, project: pair.1.cwd)
        }
        var keys: [String] = []
        for _ in 0..<1200 {
            keys = workspace.paneKeys.filter {
                !MacWorkspace.PendingPane.isPending($0) && !ProjectShell.isShellKey($0)
            }
            if keys.count >= 2,
               keys.allSatisfy({ !(MacInteractionInspectionPrompts.shared[$0] ?? []).isEmpty }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard keys.count >= 2 else {
            report["panes"] = workspace.paneKeys
            report["promptCounts"] = MacInteractionInspectionPrompts.shared.mapValues(\.count)
            save("needs-two-panes-with-prompts")
            return
        }
        let a = keys[0]
        let b = keys[1]
        workspace.setMode(.chat, for: a)
        workspace.setMode(.chat, for: b)
        workspace.focus(a)
        report["a"] = a
        report["b"] = b
        report["promptCounts"] = [a: MacInteractionInspectionPrompts.shared[a]?.count ?? 0,
                                  b: MacInteractionInspectionPrompts.shared[b]?.count ?? 0]
        report["panes"] = workspace.paneKeys
        report["paneFrames"] = workspace.paneFrames.mapValues { NSStringFromRect($0) }
        report["actionError"] = workspace.actionError ?? ""

        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible }) else {
            save("window-missing")
            return
        }
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))

        workspace.setPromptsCardOpen(true, for: a)
        workspace.setPromptsCardOpen(true, for: b)
        report["choices"] = choices(workspace, a, b)
        // Both cards exist because both panes have prompts and the choice is
        // open. In-process SwiftUI accessibility exposes no card controls, so
        // the buttons are pressed by an external accessibility client; these
        // counts are recorded as that known limitation, not as a gate.
        try? await Task.sleep(for: .seconds(3))
        report["inProcessOpenControls"] = controls("corral.prompts.hide", in: window).count
        report["appActive"] = NSApp.isActive
        report["windowKey"] = window.isKeyWindow
        report["panes"] = workspace.paneKeys
        report["identifiers"] = identifiers(in: window)
        report["views"] = viewDump(window.contentView)
        save("both-open")
        // Screenshot window: two cards open in a split. An external
        // accessibility client presses one card's own collapse button here
        // (in-process SwiftUI accessibility exposes no card controls), so the
        // probe waits for that one choice to flip and records which changed.
        let pressed = await waitForCollapse(workspace, a, b)
        let after = choices(workspace, a, b)
        report["after-collapse"] = after
        report["oneCardCollapsed"] = after.values.filter { $0 == false }.count == 1
        report["otherCardKeptOpen"] = (after[a] == true && after[b] == false)
            || (after[a] == false && after[b] == true)
        report["openControlsAfterCollapse"] = controls("corral.prompts.hide", in: window).count
        report["bubbleControlsAfterCollapse"] = controls("corral.prompts.toggle", in: window).count
        report["collapsePressed"] = pressed
        save("one-collapsed")
        guard pressed else { return }
        // Screenshot window: one card open, the other collapsed to its bubble.
        try? await Task.sleep(for: .seconds(8))

        // Per-session memory: the collapsed session keeps its choice when its
        // pane closes and the same session is opened again.
        let collapsed = after[a] == false ? a : b
        let expanded = collapsed == a ? b : a
        workspace.setPromptsCardOpen(false, for: collapsed)
        workspace.closePane(collapsed)
        _ = await wait { !workspace.paneKeys.contains(collapsed) }
        try? await Task.sleep(for: .seconds(1))
        workspace.open(collapsed, sessions: sessions)
        let reopened = await wait { workspace.paneKeys.contains(collapsed) }
        try? await Task.sleep(for: .seconds(2))
        report["reopenedPane"] = reopened
        report["rememberedCollapsed"] = workspace.promptsCardChoice(for: collapsed) == false
        report["reopenedShowsBubble"] = await wait {
            controls("corral.prompts.toggle", in: window).count == 1
                && controls("corral.prompts.hide", in: window).count == 0
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        report["expandedPaneKept"] = workspace.promptsCardChoice(for: expanded) == true
        save("reopened")
        // Screenshot window: the reopened session's remembered bubble beside
        // the other pane's still-open card; the external client presses it.
        try? await Task.sleep(for: .seconds(15))

        // Reopen the remembered session from its own bubble button. The
        // external accessibility client presses it once the bubble is on
        // screen; the probe waits for this session's choice to return.
        let bubblePressed = await wait({
            workspace.promptsCardChoice(for: collapsed) == true
        }, attempts: 2400)
        report["bubblePressed"] = bubblePressed
        report["bubbleOpenedCard"] = bubblePressed
        save("bubble-opened")
        // Screenshot window: the reopened card is open again.
        try? await Task.sleep(for: .seconds(8))

        // Close the panes the probe opened so the host group it formed
        // dissolves; the restored layout was already cleared at the start.
        for key in [a, b] where workspace.paneKeys.contains(key) {
            workspace.closePane(key)
        }
        try? await Task.sleep(for: .seconds(1))
        save("closed")
    }

    private static func choices(_ workspace: MacWorkspace, _ a: String, _ b: String) -> [String: Bool] {
        [a: workspace.promptsCardChoice(for: a) ?? false,
         b: workspace.promptsCardChoice(for: b) ?? false]
    }

    /// Every control with this accessibility identifier, in tree order.
    private static func controls(_ identifier: String, in window: NSWindow) -> [NSObject] {
        guard let root = window.contentView else { return [] }
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if (object as? any NSAccessibilityProtocol)?.accessibilityIdentifier() == identifier {
                found.append(object)
            }
            for child in ((object as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? []).compactMap({ $0 as? NSObject }) {
                walk(child)
            }
            if let view = object as? NSView {
                for child in view.subviews { walk(child) }
            }
        }
        walk(root)
        return found
    }

    /// Classes, frames and identifiers of the native host tree, so a missing
    /// accessibility control is diagnosable without a pointer.
    private static func viewDump(_ root: NSView?) -> [[String: Any]] {
        guard let root else { return [] }
        var rows: [[String: Any]] = []
        func walk(_ view: NSView, depth: Int) {
            guard depth < 16 else { return }
            var row: [String: Any] = ["class": String(describing: type(of: view)),
                                      "frame": NSStringFromRect(view.frame),
                                      "hidden": view.isHiddenOrHasHiddenAncestor,
                                      "depth": depth]
            let id = view.accessibilityIdentifier()
            if !id.isEmpty { row["id"] = id }
            if let button = view as? NSButton { row["title"] = button.title }
            rows.append(row)
            for child in view.subviews { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return Array(rows.prefix(600))
    }

    private static func identifiers(in window: NSWindow) -> [String] {
        guard let root = window.contentView else { return [] }
        var seen = Set<ObjectIdentifier>()
        var values: [String] = []
        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let id = (object as? any NSAccessibilityProtocol)?.accessibilityIdentifier() ?? ""
            if !id.isEmpty { values.append(id) }
            for child in ((object as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? []).compactMap({ $0 as? NSObject }) {
                walk(child)
            }
            if let view = object as? NSView {
                for child in view.subviews { walk(child) }
            }
        }
        walk(root)
        return Array(values.prefix(200))
    }

    /// Waits for the external collapse press: exactly one session's choice
    /// flips to closed and the other keeps its own state.
    private static func waitForCollapse(_ workspace: MacWorkspace, _ a: String, _ b: String) async -> Bool {
        for _ in 0..<3600 {
            let values = choices(workspace, a, b)
            let closed = values.values.filter { $0 == false }.count
            if closed == 1 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func wait(_ condition: () -> Bool, attempts: Int = 600) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
#endif
