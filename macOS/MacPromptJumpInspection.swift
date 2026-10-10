#if DEBUG
import Foundation

/// Debug-only prompt jump acceptance (`-CorralInspectPromptJump`, with
/// `-CorralInspectConversation` and `CORRAL_INSPECTION_SESSION_KEY` naming a long
/// session). The pane jumps to its first prompt (far: fades through), the second
/// (near: glides) and the last; each step first writes its name to
/// `/tmp/corral-mac-prompt-jump-step.txt` so an external sampler can capture frames.
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
        guard list.count >= 3 else {
            mark("error: fewer than three prompts")
            return
        }
        try? await Task.sleep(for: .seconds(4))
        for (name, prompt) in [("first", list[0]), ("second", list[1]), ("last", list[list.count - 1])] {
            mark(name)
            try? await Task.sleep(for: .milliseconds(400))
            workspace.scrollToPrompt(ConversationTimelineItem.message(prompt).id, in: key)
            try? await Task.sleep(for: .seconds(4))
        }
        mark("done")
    }

    private static func mark(_ step: String) {
        try? step.write(toFile: stepPath, atomically: true, encoding: .utf8)
    }
}
#endif
