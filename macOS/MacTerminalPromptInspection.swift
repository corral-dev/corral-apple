#if DEBUG
import AppKit
import Foundation

/// Production card → request → encrypted host → native agent → displayed widget.
/// Only an explicitly named disposable prompt-navigation fixture can enable it.
@MainActor
enum MacTerminalPromptInspection {
    private static var claimed = false

    static func start(session: SessionSummary, store: ConversationStore?, workspace: MacWorkspace) {
        Task { await run(session: session, store: store, workspace: workspace) }
    }

    static func run(session: SessionSummary, store: ConversationStore?, workspace: MacWorkspace) async {
        let env = ProcessInfo.processInfo.environment
        let transportOnly = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalPromptTransport")
        guard !claimed, (ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalPrompts") || transportOnly),
              env["CORRAL_INSPECTION_SESSION_KEY"] == session.key,
              session.cwd.contains("prompt-navigation-"),
              let path = env["CORRAL_INSPECTION_PROMPT_OUTPUT"], let store else { return }
        claimed = true
        var reports: [[String: Any]] = []
        var inputInterruptedNavigation = false
        func save(_ phase: String, targetSeq: Int? = nil, error: String? = nil) {
            var value: [String: Any] = ["phase": phase, "cases": reports,
                                        "inputRoute": "windowEvent",
                                        "inputInterruptedNavigation": inputInterruptedNavigation]
            if let targetSeq { value["targetSeq"] = targetSeq }
            if let error { value["error"] = error }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        guard await wait({ store.userPrompts.count == 50 && RemoteTerminalStream.inspectionStream?.phase == .live }),
              let view = RemoteTerminalStream.inspectionStream?.sink as? TerminalHostView,
              view.window != nil else {
            save("failed", error: "Production prompt outline / native stream did not become ready")
            return
        }
        workspace.focus(session.key)
        view.inspectionFocus()
        guard view.inspectionHasKeyboardFocus else {
            save("failed", error: "Native terminal did not receive initial keyboard focus")
            return
        }
        for number in [17, 7, 27] {
            let prompt = store.userPrompts[number]
            let before = view.inspectionVisibleText.joined(separator: "\n")
            // The existing trusted external accessibility client invokes the
            // production SwiftUI Button. No direct callback bypass is used.
            save("before\(number)", targetSeq: prompt.seq)
            let started = Date()
            if transportOnly {
                Task {
                    _ = await RemoteTerminalStream.inspectionStream?.navigatePrompt(
                        seq: prompt.seq, historyGeneration: store.promptHistoryGeneration)
                }
            }
            var frames: [String] = []
            let target = String(format: "CODEX_ANSWER_%03d", number)
            let arrived = await wait {
                frames.append(view.inspectionVisibleText.joined(separator: "\n"))
                return view.inspectionContains(target)
            }
            let elapsed = Date().timeIntervalSince(started) * 1000
            let final = view.inspectionVisibleText.joined(separator: "\n")
            let first = final.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            reports.append([
                "selectedTurn": number, "seq": prompt.seq, "generation": store.promptHistoryGeneration,
                "transportOnly": transportOnly,
                "targetVisible": arrived,
                "elapsedMs": elapsed, "framesSampled": frames.count,
                "onlyInitialAndFinal": frames.allSatisfy { $0 == before || $0 == final },
                "noFindUI": frames.allSatisfy { !$0.contains("Find:") && !$0.contains("Find ·") },
                "firstNativeContent": String(first),
                "cardOpen": workspace.promptsOpen[session.key] == true,
                "draftPreserved": view.inspectionContains("UNSENT_DRAFT_CODEX"),
                "keyboardFocusPreserved": view.inspectionHasKeyboardFocus,
            ])
            save("after\(number)")
            guard arrived else { return }
            try? await Task.sleep(for: .milliseconds(1000))
        }
        if transportOnly, let stream = RemoteTerminalStream.inspectionStream {
            let pending = Task {
                await stream.navigatePrompt(seq: store.userPrompts[7].seq,
                                            historyGeneration: store.promptHistoryGeneration)
            }
            try? await Task.sleep(for: .milliseconds(150))
            view.inspectionPressKeys(["Z"])
            _ = await pending.value
            inputInterruptedNavigation = await wait {
                view.inspectionContains("UNSENT_DRAFT_CODEXZ")
                    && !view.inspectionContains("Find:") && stream.phase == .live
            }
            guard inputInterruptedNavigation else {
                save("failed", error: "Ordinary input did not safely retire native navigation")
                return
            }
        }
        // Do not refocus after navigation: losing the ordinary input path is
        // a regression, not something the acceptance helper should conceal.
        let marker = "MAC_ORDINARY_AFTER_JUMP"
        for character in marker {
            view.inspectionPressKeys([String(character)])
            try? await Task.sleep(for: .milliseconds(30))
        }
        // Model a separate Return key, rather than a same-instant text+Return
        // burst that native agents deliberately treat as a pasted block.
        try? await Task.sleep(for: .milliseconds(200))
        view.inspectionPressKeys(["\r"])
        save("submitted")
    }

    private static func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

}
#endif
