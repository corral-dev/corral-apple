#if DEBUG
import AppKit

/// Real mounted slots and native composer input. Never sends a prompt or moves
/// the system pointer. Restores pane modes, drafts and workspace on completion.
@MainActor enum MacPaneInputInspection {
    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        let sessions = feed.listStore.windowSessions.filter {
            !$0.live && workspace.layout.group(containing: $0.key) == nil
        }
        let projects = Dictionary(grouping: sessions, by: \.cwd)
        guard let peers = projects.values.filter({ $0.count >= 3 }).max(by: { $0.count < $1.count }) else {
            write(["error": "needs three ended, ungrouped sessions in one project"])
            return
        }
        let original = workspace.paneKeys, focus = workspace.focusedKey
        let keys = Array(peers.prefix(3).map(\.key))
        let modes = keys.map { workspace.mode(for: $0) }
        func restore() {
            for (index, key) in keys.enumerated() { workspace.setMode(modes[index], for: key) }
            workspace.inspectionRestoreWorkspace(keys: original, focus: focus)
        }
        defer { restore() }
        workspace.restorePanes(keys)
        for key in keys { workspace.setMode(.chat, for: key) }
        var checks: [String: Bool] = [:]
        var windowID = 0
        for _ in 0..<80 {
            if keys.allSatisfy({ key in
                guard let root = workspace.paneSurfaces.existingEntry(for: key)?.view else { return false }
                return root.window != nil && MacComposerInputAnchor.field(in: root) != nil
                    && descendants(root).contains { view in
                        guard let text = view as? NSTextView else { return false }
                        return !text.isEditable && text.isSelectable && !text.visibleRect.isEmpty && !text.string.isEmpty
                    }
            }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        for (index, key) in keys.enumerated() {
            guard let root = workspace.paneSurfaces.existingEntry(for: key)?.view,
                  let window = root.window,
                  let field = MacComposerInputAnchor.field(in: root),
                  let observer = descendants(window.contentView).compactMap({ $0 as? MacPaneInteraction.EventView })
                    .first(where: { $0.inputRoot?() === root }) else {
                checks["pane\(index + 1)Mounted"] = false
                continue
            }
            windowID = window.windowNumber
            // Invoke the actual mounted observer at the header, body, composer
            // and bottom blank space. Fixture tests separately dispatch presses
            // through NSApp and assert the native target receives each click.
            for (region, fraction) in [("header", 0.02), ("body", 0.35), ("composer", 0.91), ("bottom", 0.99)] {
                let local = NSPoint(x: observer.bounds.midX, y: observer.bounds.height * fraction)
                let point = observer.convert(local, to: nil)
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                else { continue }
                _ = observer.handle(event)
                checks["pane\(index + 1)-\(region)Activation"] = workspace.focusedKey == key
            }
            try? await Task.sleep(for: .milliseconds(300))
            let saved = field.stringValue
            let text = descendants(root).compactMap { $0 as? NSTextView }
                .first { !$0.isEditable && $0.isSelectable && !$0.visibleRect.isEmpty && !$0.string.isEmpty }
            guard let text else { checks["pane\(index + 1)Selection"] = false; continue }
            let range = text.selectedRange()
            window.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: 0, length: min(6, (text.string as NSString).length)))
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) {
                NSApp.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(300))
            checks["pane\(index + 1)SelectionToTyping"] = field.stringValue != saved && field.stringValue.contains("x")
            checks["pane\(index + 1)ComposerResponder"] = (window.firstResponder as? NSTextView)?.isEditable == true
            if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                editor.insertText(saved, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            }
            text.setSelectedRange(range)
            checks["pane\(index + 1)DraftRestored"] = field.stringValue == saved
        }
        write(["checks": checks, "keys": keys, "focused": workspace.focusedKey ?? "",
               "windowID": windowID, "holding": true])
        let hold = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_HOLD_SECONDS"].flatMap(Double.init) ?? 15
        try? await Task.sleep(for: .seconds(hold))
        restore()
        try? await Task.sleep(for: .milliseconds(800))
        write(["checks": checks, "keys": keys, "windowID": windowID, "holding": false,
               "workspaceRestored": workspace.paneKeys == original && workspace.focusedKey == focus])
    }

    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private static func write(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pane-input.json"), options: .atomic)
        }
    }
}
#endif
