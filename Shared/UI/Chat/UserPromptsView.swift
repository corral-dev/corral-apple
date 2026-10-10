import SwiftUI

/// Large sheet of real user prompts for the open session (Your prompts on mobile).
struct UserPromptsView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let prompts: [RichMessage]
    var onSelect: ((RichMessage) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sessionTextScale) private var sessionTextScale

    var body: some View {
        NavigationStack {
            Group {
                if prompts.isEmpty {
                    ContentUnavailableView {
                        Label("session.detail.user_prompts.empty.title", systemImage: "text.bubble")
                    } description: {
                        Text("session.detail.user_prompts.empty.description")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
                            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                                Button {
                                    onSelect?(prompt)
                                    dismiss()
                                } label: {
                                    promptCard(index: index, prompt: prompt)
                                }
                                .buttonStyle(PressableButtonStyle())
                                .accessibilityHint(Text("session.detail.user_prompts.jump_hint"))
                            }
                        }
                        .interfacePadding(.horizontal, Space.base)
                        .interfacePadding(.vertical, Space.md)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("session.detail.user_prompts")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .corralTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .interfaceFont(.title2)
                            .foregroundStyle(.secondary)
                            .interfaceFrame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(Text("action.dismiss"))
                }
            }
        }
        .environment(\.sessionTextScale, sessionTextScale)
    }

    private func promptCard(index: Int, prompt: RichMessage) -> some View {
        HStack(alignment: .top, spacing: Space.md * interfaceScale) {
            Text("\(index + 1)")
                .interfaceFont(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .interfaceFrame(width: 28, height: 28)
                .background(Palette.warmSurface, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                if let stamp = timeLabel(for: prompt) {
                    Text(stamp)
                        .interfaceFont(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(prompt.text ?? "")
                    .sessionFont(.bubbleBody)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            }

            Image(systemName: "chevron.right")
                .interfaceFont(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .interfacePadding(.top, 6)
                .accessibilityHidden(true)
        }
        .interfacePadding(Space.md)
        .background(
            Palette.assistantBubble,
            in: RoundedRectangle(cornerRadius: Radius.lg * interfaceScale, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg * interfaceScale, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .interfaceFrame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Radius.lg * interfaceScale, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(promptAccessibilityLabel(index: index, prompt: prompt))
    }

    private func promptAccessibilityLabel(index: Int, prompt: RichMessage) -> Text {
        let body = prompt.text ?? ""
        if let stamp = timeLabel(for: prompt) {
            return Text("\(index + 1). \(stamp). \(body)")
        }
        return Text("\(index + 1). \(body)")
    }

    private func timeLabel(for prompt: RichMessage) -> String? {
        guard let timestamp = prompt.timestamp, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = Calendar.current.isDateInToday(date) ? Self.todayFormatter : Self.olderFormatter
        return formatter.string(from: date)
    }

    private static let todayFormatter = promptFormatter("HH:mm")
    private static let olderFormatter = promptFormatter("MM-dd HH:mm")

    private static func promptFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }
}
