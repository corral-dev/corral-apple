import AppKit
import SwiftUI

/// The pane's Your prompts card (design: Prompts card). It floats at the
/// pane's top trailing corner: beside the conversation when the pane has
/// room (the pane shifts the conversation aside by `reserve`), over it in
/// narrow panes, where it starts collapsed into the pane header's button.
/// Over content it behaves like a transient popover: a mouse click outside
/// it closes it, and the click still reaches its target.
struct MacPromptsCard: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let prompts: [RichMessage]
    @Binding var isOpen: Bool
    var width: CGFloat = MacPromptsCard.width
    /// Floating over content in a narrow pane rather than beside it.
    var overContent = false
    var onTerminal = false
    var maxListHeight: CGFloat = 360
    /// The clicked row's jump status, shown in place of its time.
    var status: TerminalPromptRowStatus? = nil
    var onSelect: (RichMessage) -> Void = { _ in }

    static let width: CGFloat = 300
    /// Over content the card leaves part of the narrow pane visible.
    static let overContentWidthFraction: CGFloat = 0.6
    static let overContentMinimumWidth: CGFloat = 220
    /// Over content the whole card stays within about a third of the pane.
    static let overContentHeightFraction: CGFloat = 1.0 / 3
    /// Trailing space the conversation gives up when the card sits beside it.
    static let reserve: CGFloat = width + Space.md * 2
    /// Narrowest reading column the conversation keeps beside the card.
    static let minimumReadingWidth: CGFloat = 600
    static let cornerRadius: CGFloat = 14
    private static let rowInset: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var listHeight: CGFloat = 0
    @State private var hoveredID: RichMessage.ID?
    @State private var currentID: RichMessage.ID?
    @State private var clickMonitor: Any?
    @State private var cardAnchor = PromptsCardClickAnchor()

    var body: some View {
        // Collapsed, the card is controlled from the pane's session menu, so
        // nothing floats over the conversation (design: Pane header composition).
        Group {
            if isOpen {
                card
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .onAppear { updateClickMonitor() }
        .onChange(of: isOpen) { _, _ in updateClickMonitor() }
        .onChange(of: overContent) { _, _ in updateClickMonitor() }
        .onDisappear { removeClickMonitor() }
    }

    // MARK: - Outside dismissal (design: Prompts card, rule 5)

    /// A card floating over content closes on a mouse click outside it,
    /// like a transient popover; the click still reaches its target, so no
    /// second click is needed. A card docked beside the conversation is not
    /// a popup and never closes this way.
    private func updateClickMonitor() {
        guard overContent && isOpen else {
            removeClickMonitor()
            return
        }
        guard clickMonitor == nil else { return }
        let anchor = cardAnchor
        let presentation = $isOpen
        let motion = reduceMotion
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let view = anchor.view, let window = view.window else { return event }
            // A click into another window of this app closes a transient
            // popup too.
            guard event.window === window else {
                withAnimation(MacMotion.disclosure(reduceMotion: motion)) { presentation.wrappedValue = false }
                return event
            }
            let cardRect = view.convert(view.bounds, to: nil)
            if !cardRect.contains(event.locationInWindow) {
                withAnimation(MacMotion.disclosure(reduceMotion: motion)) { presentation.wrappedValue = false }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: - Open

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2 * interfaceScale) {
                        ForEach(prompts) { prompt in
                            row(prompt).id(prompt.id)
                        }
                    }
                    .nativeOverlayScrollers()
                    .interfacePadding(Self.rowInset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(listHeight, 1), maxListHeight))
                .task(id: prompts.last?.id) {
                    await Task.yield()
                    guard !Task.isCancelled, let last = prompts.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(width: width)
        .background {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius * interfaceScale, style: .continuous)
            shape.fill(onTerminal ? Color(nsColor: TerminalAppearance.background) : Color(.systemGroupedBackground))
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.045))
        }
        // Live window rect for the outside-click monitor. It fills the card
        // but never takes part in hit testing, so clicks inside the card
        // keep reaching the card's own controls.
        .background {
            PromptsCardAnchorView(anchor: cardAnchor)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius * interfaceScale, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(overContent ? 0.10 : 0.06), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius * interfaceScale, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm * interfaceScale) {
            Text("session.detail.user_prompts")
                .interfaceFont(.headline)
            Text(verbatim: prompts.count.formatted())
                .interfaceFont(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.sm * interfaceScale)
            Button {
                setOpen(false)
            } label: {
                Image(systemName: "chevron.up")
                    .interfaceFont(.callout.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help(Text("mac.prompts.hide"))
            .accessibilityLabel(Text("mac.prompts.hide"))
        }
        .interfacePadding(.horizontal, Space.md + Self.rowInset / 2)
        .interfacePadding(.top, Space.md)
        .interfacePadding(.bottom, Space.xs)
        .contentShape(Rectangle())
        .onTapGesture { setOpen(false) }
    }

    private func row(_ prompt: RichMessage) -> some View {
        Button {
            currentID = prompt.id
            onSelect(prompt)
        } label: {
            Group {
                if overContent {
                    compactRowContent(prompt)
                } else {
                    rowContent(prompt)
                }
            }
            .interfacePadding(.horizontal, Space.sm + 2)
            .interfacePadding(.vertical, overContent ? 5 : 7)
            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill(prompt.id), in: rowShape)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("corral.prompt.\(prompt.seq)")
        .onHover { inside in
            if inside { hoveredID = prompt.id } else if hoveredID == prompt.id { hoveredID = nil }
        }
        // Compact rows cut long prompts at two lines; hovering shows the rest.
        .help(overContent ? Text(verbatim: Self.hoverText(prompt)) : Text("mac.prompts.jump"))
    }

    private func rowContent(_ prompt: RichMessage) -> some View {
        VStack(alignment: .leading, spacing: 2 * interfaceScale) {
            if let kind = statusKind(prompt) {
                statusText(kind)
            } else if let stamp = Self.timeLabel(prompt) {
                stampText(stamp)
            }
            promptText(prompt, lineLimit: 4)
        }
    }

    /// Over content the card is small, so the time moves beside the text
    /// and the text keeps two lines (design: Prompts card rule 4).
    private func compactRowContent(_ prompt: RichMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm * interfaceScale) {
            promptText(prompt, lineLimit: 2)
            Spacer(minLength: 0)
            if let kind = statusKind(prompt) {
                statusText(kind)
                    .fixedSize()
            } else if let stamp = Self.timeLabel(prompt) {
                stampText(stamp)
                    .fixedSize()
            }
        }
    }

    private func statusKind(_ prompt: RichMessage) -> TerminalPromptRowStatus.Kind? {
        status?.seq == prompt.seq ? status?.kind : nil
    }

    private func statusText(_ kind: TerminalPromptRowStatus.Kind) -> some View {
        TerminalPromptStatusLabel(kind: kind)
            .interfaceFont(.caption)
    }

    private func stampText(_ stamp: String) -> some View {
        Text(verbatim: stamp)
            .interfaceFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func promptText(_ prompt: RichMessage, lineLimit: Int) -> some View {
        Text(verbatim: Self.oneLine(prompt))
            .interfaceFont(.body)
            .foregroundStyle(.primary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    /// Concentric with the card: card radius minus the row inset.
    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: (Self.cornerRadius - Self.rowInset) * interfaceScale, style: .continuous)
    }

    private func rowFill(_ id: RichMessage.ID) -> Color {
        if currentID == id { return Color.accentColor.opacity(0.16) }
        if hoveredID == id { return Color.primary.opacity(0.06) }
        return .clear
    }

    private func setOpen(_ open: Bool) {
        withAnimation(MacMotion.disclosure(reduceMotion: reduceMotion)) { isOpen = open }
    }

    private static func oneLine(_ prompt: RichMessage) -> String {
        (prompt.text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Bounded so a very long prompt does not open a screen-sized tooltip.
    private static func hoverText(_ prompt: RichMessage) -> String {
        let text = oneLine(prompt)
        return text.count > 800 ? String(text.prefix(800)) + "…" : text
    }

    /// `HH:mm` today, `MM-dd HH:mm` earlier; nothing when the history has no time.
    private static func timeLabel(_ prompt: RichMessage) -> String? {
        guard let timestamp = prompt.timestamp, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return (Calendar.current.isDateInToday(date) ? todayFormatter : olderFormatter).string(from: date)
    }

    private static let todayFormatter = formatter("HH:mm")
    private static let olderFormatter = formatter("MM-dd HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }
}

/// Holds the floating card's AppKit view so the outside-click monitor can
/// test a mouse-down against the card's live window rect instead of a stale
/// snapshot. The reference is weak; the monitor is removed with the view.
private final class PromptsCardClickAnchor: NSObject {
    weak var view: NSView?
}

/// Fills the card's bounds as a background. Hit testing stays disabled, so
/// this view never becomes a click target; only its window rect is read.
private struct PromptsCardAnchorView: NSViewRepresentable {
    let anchor: PromptsCardClickAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
