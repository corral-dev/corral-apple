import SwiftUI
#if os(macOS)
import AppKit
#endif

enum ChatActivityState: Equatable {
    case working, tool, waiting

    static func resolve(
        live: Bool, connected: Bool, attention: AttentionKind,
        hasPrompt: Bool, hasRunningTool: Bool,
        marker: SessionPresentation.StatusMarker? = nil
    ) -> Self? {
        // The cue follows the activity dot: green (`working` or `recent`)
        // shows Working, yellow shows the waiting cue. Red unread is an
        // independent overlay and never drives (or suppresses) this cue.
        let greenDot = marker == .working || marker == .recent
        let working = attention == .working || greenDot
        // Sending resumes an ended session, so fresh or provisional activity wins
        // over a stale not-live flag.
        let waiting = attention == .waiting || marker == .waiting
        guard connected, live || working || waiting else { return nil }
        if hasPrompt || waiting { return .waiting }
        guard working else { return nil }
        return hasRunningTool ? .tool : .working
    }

    /// One resolution for the activity cue and the composer's stop button.
    static func resolve(
        store: ConversationStore, connected: Bool, marker: SessionPresentation.StatusMarker?
    ) -> Self? {
        resolve(
            live: store.isLive,
            connected: connected,
            attention: store.displayAttention,
            hasPrompt: !store.prompts.isEmpty,
            hasRunningTool: store.hasRunningTool,
            marker: marker
        )
    }

    /// The assistant is executing a turn; waiting for a reply is not running.
    var isRunning: Bool { self != .waiting }

    /// A turn the stop button can interrupt. The host's `recent` green dot only
    /// means a hosted session was active within the just-now window — a freshly
    /// created, never-prompted session qualifies — so it shows Working but never
    /// counts as a running turn on its own.
    static func hasRunningTurn(
        state: Self?, attention: AttentionKind, hasRunningTool: Bool,
        marker: SessionPresentation.StatusMarker?
    ) -> Bool {
        guard state?.isRunning == true else { return false }
        return attention == .working || marker == .working || hasRunningTool
    }

    var label: LocalizedStringResource {
        switch self {
        case .working: "chat.activity.working"
        case .tool: "chat.activity.tool"
        case .waiting: "chat.activity.waiting"
        }
    }
}

/// A quiet activity cue in the reading flow, never a floating status panel.
struct ChatActivityFooter: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let state: ChatActivityState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.sm * interfaceScale) {
            if state == .waiting {
                Image(systemName: "text.bubble")
                    .foregroundStyle(Palette.attentionWaiting)
            } else if reduceMotion {
                staticDots
            } else {
                #if os(macOS)
                MacWorkingDots(color: NSColor(Palette.attentionWorking))
                    .interfaceFrame(width: 23, height: 16)
                    .accessibilityHidden(true)
                #else
                IOSWorkingDots(color: UIColor(Palette.attentionWorking))
                    .interfaceFrame(width: 23, height: 16)
                    .accessibilityHidden(true)
                #endif
            }
            Text(state.label)
                .interfaceFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .interfacePadding(.vertical, Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.label))
        .accessibilityIdentifier("chat.activityFooter")
    }

    /// Static dots for Reduce Motion; the animated cue is `MacWorkingDots` / `IOSWorkingDots`
    /// (Core Animation, so an always-visible cue costs no per-frame SwiftUI work).
    private var staticDots: some View {
        HStack(spacing: 4 * interfaceScale) {
            ForEach(0..<3) { _ in
                Circle()
                    .fill(Palette.attentionWorking)
                    .interfaceFrame(width: 5, height: 5)
            }
        }
        .interfaceFrame(height: 16)
        .accessibilityHidden(true)
    }
}
