import SwiftUI

/// Restart feedback shared by the composer row, the iPhone header and the Mac
/// pane header (design: UI KB, immediate restart feedback 2026-10-20).
struct SessionRestartStatusLabel: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let phase: SessionRestartTracker.Phase
    var font: Font = .footnote
    /// Headers use the short wording; the composer row names the session.
    var compact = false

    var body: some View {
        HStack(spacing: Space.xs * interfaceScale) {
            switch phase {
            case .restarting:
                ProgressView()
                    .interfaceControlSize(.mini)
            case .restarted:
                Image(systemName: "checkmark.circle.fill")
                    .interfaceFont(font)
                    .foregroundStyle(Palette.attentionWorking)
            }
            Text(label)
                .interfaceFont(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private var label: LocalizedStringKey {
        switch phase {
        case .restarting: compact ? "session.actions.restarting" : "session.actions.restarting_session"
        case .restarted: "session.actions.restarted"
        }
    }
}

/// The composer-area row: visible in an empty conversation too, unlike the
/// activity cue, which lives inside the message list.
struct SessionRestartStatusRow: View {
    let phase: SessionRestartTracker.Phase

    var body: some View {
        SessionRestartStatusLabel(phase: phase)
            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            .interfacePadding(.horizontal, Space.base)
            .interfacePadding(.vertical, Space.xs)
            .accessibilityIdentifier("session.restartStatus")
    }
}
