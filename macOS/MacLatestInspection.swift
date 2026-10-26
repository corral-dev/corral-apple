#if DEBUG
import AppKit
import Foundation

/// Actual card Button → encrypted host → disposable fullscreen agent.
/// Reuses MacZoomInspection's public accessibility action, never the pointer.
@MainActor
enum MacLatestInspection {
    private static var claimed = false

    /// Open the disposable acceptance pane without a pointer before the view
    /// task can run. The fixture cwd keeps this away from real sessions.
    static func prepare(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalLatest"),
              let key = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"]
        else { return }
        for _ in 0..<120 where feed.listStore.session(for: key) == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let session = feed.listStore.session(for: key),
              session.cwd.contains("latest-acceptance") else { return }
        workspace.open(key, sessions: [session])
        workspace.setMode(.terminal, for: key)
    }

    static func start(session: SessionSummary, store: ConversationStore?,
                      workspace: MacWorkspace, appModel: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard !claimed, ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalLatest"),
              env["CORRAL_INSPECTION_SESSION_KEY"] == session.key,
              session.cwd.contains("latest-acceptance"), let store,
              let path = env["CORRAL_INSPECTION_LATEST_OUTPUT"] else { return }
        claimed = true
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Corral" })?.makeKeyAndOrderFront(nil)
        let early = ["phase": "started", "session": session.key, "cwd": session.cwd] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: early, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        Task { await run(session: session, store: store, workspace: workspace, appModel: appModel, path: path) }
    }

    private static func run(session: SessionSummary, store: ConversationStore,
                            workspace: MacWorkspace, appModel: AppModel, path: String) async {
        var report: [String: Any] = [:]
        var cases: [[String: Any]] = []
        func save(_ phase: String) {
            report["phase"] = phase
            report["cases"] = cases
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        save("starting")
        guard await wait({ store.userPrompts.count == 50 && workspace.terminals.terminal(
            for: session.key, client: appModel.client)?.stream.phase == .live },
            attempts: 2400),
              let terminal = workspace.terminals.terminal(for: session.key, client: appModel.client),
              workspace.paneSurfaces.existingEntry(for: session.key) != nil else {
            report["prompts"] = store.userPrompts.count
            report["terminal_phase"] = workspace.terminals.terminal(for: session.key, client: appModel.client)
                .map { "\($0.stream.phase)" } ?? "no-terminal"
            report["pane"] = workspace.paneSurfaces.existingEntry(for: session.key) != nil
            save("not-ready")
            return
        }
        for attempt in 0..<2 {
            workspace.promptsOpen[session.key] = true
            // Fixture only. Native history is not SwiftTerm's local scrollback.
            terminal.stream.input.send(Array("\u{1b}[1;5H".utf8)[...])
            guard await wait({ terminal.view.inspectionContains("CODEX_PROMPT_000") }) else {
                save("history-not-ready")
                return
            }
            save("before-\(attempt)")
            try? await Task.sleep(for: .seconds(3))
            let methodOnly = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_LATEST_METHOD"] == "1"
            var cardScrolled = false
            if !methodOnly, let root = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible })?.contentView,
               let scroll = promptsScroll(in: root), let document = scroll.documentView {
                // Production card scroll: bring its fixed last row into view
                // before the real accessibility press. Nothing is typed.
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                cardScrolled = true
                for _ in 0..<8 {
                    if latestButton(in: root) != nil { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            report["cardScrolled"] = cardScrolled
            let before = terminal.view.inspectionVisibleText.joined(separator: "\n")
            let start = Date()
            let pressed: Bool
            if methodOnly {
                // Same production method the row's Button calls; the background
                // window cannot expose SwiftUI virtual rows to accessibility.
                workspace.scrollToLatest(in: session.key)
                pressed = true
            } else {
                guard let root = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible })?.contentView else {
                    save("button-missing")
                    return
                }
                guard let control = latestButton(in: root) as? any NSAccessibilityProtocol else {
                    report["identifiers"] = identifiers(in: root)
                    report["views"] = viewDump(root)
                    save("button-missing")
                    return
                }
                pressed = control.accessibilityPerformPress()
            }
            let arrived = await wait({ terminal.view.inspectionContains("CODEX_ANSWER_049") })
            cases.append(["nativeButtonPressed": pressed, "methodOnly": methodOnly, "latestVisible": arrived,
                          "draftPreserved": terminal.view.inspectionContains("UNSENT_DRAFT_CODEX"),
                          "modePreserved": workspace.mode(for: session.key) == .terminal,
                          "cardOpen": workspace.promptsOpen[session.key] == true,
                          "screenChanged": before != terminal.view.inspectionVisibleText.joined(separator: "\n"),
                          "elapsedMs": Date().timeIntervalSince(start) * 1000])
            save("after-\(attempt)")
            guard pressed && arrived else { return }
            try? await Task.sleep(for: .seconds(3))
        }
        // Use the production terminal input sender, with no focus repair.
        terminal.stream.input.send(Array("MAC_NEXT_AFTER_LATEST".utf8)[...])
        try? await Task.sleep(for: .milliseconds(250))
        terminal.stream.input.send([13][...])
        save("submitted")
        // The new prompt makes the card anchor its fixed last row. That row is
        // now on screen, so the real SwiftUI Button can be pressed through
        // accessibility instead of the workspace method.
        if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_LATEST_BUTTON"] == "1" {
            for _ in 0..<400 {
                if workspace.promptsOpen[session.key] == true { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            terminal.stream.input.send(Array("\u{1b}[1;5H".utf8)[...])
            guard await wait({ terminal.view.inspectionContains("CODEX_PROMPT_000") }) else {
                save("button-ax-history")
                return
            }
            guard let root = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible })?.contentView else {
                save("button-ax-missing")
                return
            }
            guard let control = latestButton(in: root) as? any NSAccessibilityProtocol else {
                report["identifiers"] = identifiers(in: root)
                save("button-ax-missing")
                return
            }
            let start = Date()
            let pressed = control.accessibilityPerformPress()
            let arrived = await wait({ terminal.view.inspectionContains("CODEX_ANSWER_049") })
            cases.append(["actualButton": true, "nativeButtonPressed": pressed,
                          "latestVisible": arrived,
                          "elapsedMs": Date().timeIntervalSince(start) * 1000])
            save("button-ax-after")
        }
    }

    private static func identifiers(in root: NSObject) -> [String] {
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

    private static func promptsScroll(in root: NSView) -> NSScrollView? {
        var found: NSScrollView?
        func walk(_ view: NSView) {
            if found != nil { return }
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               (250...420).contains(scroll.bounds.width), scroll.bounds.height > 200,
               document.bounds.height > scroll.contentView.bounds.height {
                found = scroll
                return
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return found
    }

    private static func viewDump(_ root: NSView) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func walk(_ view: NSView, depth: Int) {
            guard depth < 14 else { return }
            var row: [String: Any] = ["class": String(describing: type(of: view)),
                                      "frame": NSStringFromRect(view.frame),
                                      "hidden": view.isHiddenOrHasHiddenAncestor,
                                      "depth": depth]
            let id = view.accessibilityIdentifier()
            if !id.isEmpty {
                row["id"] = id
            }
            rows.append(row)
            for child in view.subviews { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return Array(rows.prefix(400))
    }

    private static func latestButton(in root: NSObject) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if (object as? any NSAccessibilityProtocol)?.accessibilityIdentifier() == "corral.prompt.latest" {
                return object
            }
            for child in ((object as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? []).compactMap({ $0 as? NSObject }) {
                if let found = find(child) { return found }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        return find(root)
    }

    private static func wait(_ condition: () -> Bool, attempts: Int = 600) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
#endif
