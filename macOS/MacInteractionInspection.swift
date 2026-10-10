#if DEBUG
import AppKit
import SwiftUI

/// Debug-only interaction acceptance (`-CorralInspectInteraction`), run on the
/// real window without driving the pointer or keyboard. Opens two ended
/// sessions outside groups as a split and checks that selecting a pane puts
/// the caret in that pane's composer (⌘1/⌘2 path, sidebar keyboard path that
/// must not move it, the composer-to-pane direction), then jumps the first
/// pane to its first prompt. Pauses between steps for window captures, writes
/// `/tmp/corral-mac-interaction.json`, and closes the panes again so the host
/// group it formed dissolves.
@MainActor
enum MacInteractionInspection {
    static let resultPath = "/tmp/corral-mac-interaction.json"
    static let pause: Double = 4

    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        let sessions = feed.listStore.windowSessions
        let ended = sessions.filter { !$0.live && workspace.layout.group(containing: $0.key) == nil }
        guard ended.count >= 3 else {
            write(["error": "needs three ended sessions outside groups"])
            return
        }
        let a = ended[0], b = ended[1], c = ended[2]
        var steps: [[String: Any]] = []
        func record(_ name: String) {
            steps.append(["step": name, "caret_pane": caretPane(workspace) ?? "none", "focused": workspace.focusedKey ?? "none"])
        }

        workspace.open(a.key, sessions: sessions, takeKeys: true)
        workspace.addPane(b.key, project: b.cwd)
        try? await Task.sleep(for: .seconds(pause))
        record("added B (expect caret B)")

        workspace.focusPane(at: 0)
        try? await Task.sleep(for: .seconds(pause))
        record("cmd-1 (expect caret A)")

        workspace.focusPane(at: 1)
        try? await Task.sleep(for: .seconds(pause))
        record("cmd-2 (expect caret B)")

        // Sidebar arrow keys: the pane opens, the caret stays where it was.
        let before = caretPane(workspace)
        workspace.open(a.key, sessions: sessions, takeKeys: false)
        try? await Task.sleep(for: .seconds(1))
        steps.append(["step": "sidebar keyboard open A (expect caret unchanged)", "caret_before": before ?? "none",
                      "caret_pane": caretPane(workspace) ?? "none", "focused": workspace.focusedKey ?? "none"])

        // Composer → pane: the caret entering A's composer selects A.
        workspace.focusPane(at: 1)
        try? await Task.sleep(for: .seconds(1))
        workspace.composerDidGainFocus(a.key)
        steps.append(["step": "composer focus A selects A", "focused": workspace.focusedKey ?? "none"])

        // Prompts card: open A's, jump to its first prompt, collapse it again.
        workspace.promptsOpen[a.key] = true
        try? await Task.sleep(for: .seconds(pause))
        record("prompts card open on A")
        if let first = MacInteractionInspectionPrompts.shared[a.key]?.first {
            workspace.scrollToPrompt(ConversationTimelineItem.message(first).id, in: a.key)
            steps.append(["step": "jump A to first prompt", "prompt": String((first.text ?? "").prefix(60))])
        }
        try? await Task.sleep(for: .seconds(pause))
        workspace.promptsOpen[a.key] = false
        try? await Task.sleep(for: .seconds(pause))
        record("prompts card collapsed (capsule)")

        workspace.closePane(b.key)
        try? await Task.sleep(for: .seconds(1))
        record("closed B (expect caret A)")
        // Empty workspace: the New Session action replaces the ⌘N sentence.
        workspace.closePane(a.key)
        _ = c
        write(["a": a.key, "b": b.key, "c": c.key, "steps": steps])
    }

    /// Pane whose frame holds the window's first responder when it is a text
    /// field editor (the composer), else nil.
    private static func caretPane(_ workspace: MacWorkspace) -> String? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Corral" }),
              let editor = window.firstResponder as? NSTextView, editor.isEditable,
              let content = window.contentView else { return nil }
        let rect = editor.convert(editor.bounds, to: nil)
        let point = CGPoint(x: rect.midX, y: content.bounds.height - rect.midY)
        return workspace.paneKey(atWindowPoint: point)
    }

    private static func write(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: resultPath))
    }
}
/// Prompts each open pane shows, published by the pane for the inspection.
@MainActor
enum MacInteractionInspectionPrompts {
    static var shared: [String: [RichMessage]] = [:]
}
#endif
