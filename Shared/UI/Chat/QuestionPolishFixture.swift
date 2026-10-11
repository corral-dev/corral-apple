#if DEBUG
import SwiftUI

/// Debug-only visual fixture for the question-card polish (owner screenshot,
/// 2026-10-11): a refused short bubble with its capped cause block, the
/// blocked question card with the quiet hint and neutral Submit, and the
/// waiting cue. Opened with `-CorralInspectQuestionPolish`; never in Release,
/// never paired, never touching a real session.
struct QuestionPolishFixtureView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme

    private static let blockingPrompt = SessionPrompt(
        id: "fixture-q",
        name: "Acceptance test",
        summary: nil,
        detail: nil,
        options: [],
        prompt: "First send any chat message (it should be refused, draft kept), then tick TWO of these options and submit. Which did you tick?",
        header: "验收",
        requestID: "fixture-req",
        questionID: "fixture-q",
        multiSelect: true,
        allowCustom: true,
        optionDetails: [
            SessionPromptOption(id: "0", label: "Apple", description: "Test option A"),
            SessionPromptOption(id: "1", label: "Banana", description: "Test option B"),
            SessionPromptOption(id: "2", label: "Cherry", description: "Test option C"),
        ],
        blocksInput: true
    )

    private static let failedBubble = RichMessage(
        seq: -1,
        role: "user",
        text: "测试",
        delivery: .failed,
        failureDetail: "The assistant is waiting for an answer to its question, so this message was not sent. Answer it in the question panel first, then send again."
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg * interfaceScale) {
                MessageBubbleView(
                    message: Self.failedBubble,
                    onRetry: {},
                    interfaceScale: interfaceScale,
                    colorScheme: colorScheme
                )
                AnswerOptionsView(
                    prompts: [Self.blockingPrompt],
                    isConnected: true,
                    showsBlockedHint: true,
                    submissionState: nil,
                    onSubmit: { _, _ in }
                )
                ChatActivityFooter(state: .waiting)
                    .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            }
            .interfacePadding(Space.base)
        }
        .background(Color(.systemGroupedBackground))
    }
}
#endif
