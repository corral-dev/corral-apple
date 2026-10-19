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
    static func start(key: String, mode: MacWorkspace.PaneMode, prompts: [RichMessage],
                      select: @escaping (RichMessage) -> Void, status: @escaping () -> TerminalPromptRowStatus?) {
        guard !claimed, ProcessInfo.processInfo.arguments.contains("-CorralInspectPromptStatus"),
              ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == key,
              mode == .terminal, prompts.count >= 2 else { return }
        claimed = true
        Task { await run(prompts: prompts, select: select, status: status) }
    }

    private static func run(prompts: [RichMessage], select: (RichMessage) -> Void,
                            status: () -> TerminalPromptRowStatus?) async {
        try? await Task.sleep(for: .seconds(6))
        var reports: [[String: Any]] = []
        for (step, prompt) in [prompts[0], prompts[prompts.count / 2]].enumerated() {
            let started = Date()
            select(prompt)
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
            reports.append(["seq": prompt.seq, "statuses": Array(NSOrderedSet(array: kinds)),
                            "seconds": ended, "after": describe(status())])
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
