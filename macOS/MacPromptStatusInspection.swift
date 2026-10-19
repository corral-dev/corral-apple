#if DEBUG
import AppKit

/// `-CorralInspectPromptStatus` with `CORRAL_INSPECTION_SESSION_KEY`: selects
/// the terminal pane's prompt rows through the production selection path and
/// captures the window while locating and after the outcome, so the row
/// status is checked without driving the pointer (also while locked).
@MainActor
enum MacPromptStatusInspection {
    private static var claimed = false

    /// Unstructured, so a prompt-list refresh does not cancel the run midway.
    static func start(key: String, mode: MacWorkspace.PaneMode, prompts: @escaping () -> [RichMessage],
                      select: @escaping (RichMessage) -> Void, status: @escaping () -> TerminalPromptRowStatus?) {
        guard !claimed, ProcessInfo.processInfo.arguments.contains("-CorralInspectPromptStatus"),
              ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == key,
              mode == .terminal, prompts().count >= 2 else { return }
        claimed = true
        Task { await run(prompts: prompts, select: select, status: status) }
    }

    private static func run(prompts current: () -> [RichMessage], select: (RichMessage) -> Void,
                            status: () -> TerminalPromptRowStatus?) async {
        try? await Task.sleep(for: .seconds(6))
        // The host's complete list replaces the loaded window's prompts.
        let prompts = current()
        var reports: [[String: Any]] = []
        // `CORRAL_INSPECTION_PROMPT_INDEXES` (comma-separated) picks the rows.
        let indexes = (ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PROMPT_INDEXES"] ?? "")
            .split(separator: ",").compactMap { Int($0) }.filter { prompts.indices.contains($0) }
        let chosen = indexes.isEmpty ? [prompts[0], prompts[prompts.count / 2]] : indexes.map { prompts[$0] }
        for (step, prompt) in chosen.enumerated() {
            let started = Date()
            let view = RemoteTerminalStream.inspectionStream?.sink as? TerminalHostView
            view?.inspectionFocus()
            try? await Task.sleep(for: .milliseconds(300))
            select(prompt)
            // `CORRAL_INSPECTION_FOCUS_CHURN=1`: the terminal loses and regains
            // focus right after the selection, as a real card click can do; its
            // focus reports must not cancel the jump.
            // `CORRAL_INSPECTION_HOVER=1`: the pointer moves over the terminal
            // while the jump runs, as it does after a real click.
            if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_HOVER"] == "1" {
                try? await Task.sleep(for: .milliseconds(400))
                view?.inspectionHover(steps: 5)
            }
            if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_FOCUS_CHURN"] == "1" {
                try? await Task.sleep(for: .milliseconds(150))
                view?.window?.makeFirstResponder(nil)
                try? await Task.sleep(for: .milliseconds(300))
                view?.inspectionFocus()
            }
            try? await Task.sleep(for: .milliseconds(300))
            capture("\(step)-locating")
            var kinds: [String] = []
            while Date().timeIntervalSince(started) < 30 {
                kinds.append(describe(status()))
                if status()?.kind != .locating { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let ended = Date().timeIntervalSince(started)
            try? await Task.sleep(for: .milliseconds(200))
            capture("\(step)-after")
            // Whether the prompt's opening is on the terminal's first rows.
            let opening = String((prompt.text ?? "").filter { !$0.isWhitespace }.prefix(8))
            let top = (view?.inspectionVisibleText.prefix(3) ?? []).joined().filter { !$0.isWhitespace }
            reports.append(["seq": prompt.seq, "statuses": Array(NSOrderedSet(array: kinds)),
                            "seconds": ended, "after": describe(status()),
                            "landedTop": !opening.isEmpty && top.contains(opening)])
            try? await Task.sleep(for: .seconds(3))
            reports[reports.count - 1]["afterExpiry"] = describe(status())
            capture("\(step)-expired")
        }
        if let data = try? JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-prompt-status.json"), options: .atomic)
        }
    }

    private static func describe(_ status: TerminalPromptRowStatus?) -> String {
        switch status?.kind {
        case .locating: "locating"
        case .absent: "absent"
        case .failed: "failed"
        case nil: "none"
        }
    }

    private static func capture(_ name: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/tmp/corral-prompt-status-\(name).png"))
    }
}
#endif
