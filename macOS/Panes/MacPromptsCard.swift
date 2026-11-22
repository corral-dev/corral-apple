import AppKit
import SwiftUI

/// Observe the card's actual limits inside the overlay. Once its width is
/// capped, a divider step can reposition it without publishing new card size.
struct MacPromptsCardViewport<Content: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var limits: CGSize = .zero
    let fitsBeside: Bool
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        let full = MacPromptsCard.width * interfaceScale
        let margin = Space.md * 2 * interfaceScale
        let minimum = MacPromptsCard.overContentMinimumWidth * interfaceScale
        let widthFraction = MacPromptsCard.overContentWidthFraction
        let heightFraction = fitsBeside ? 0.7 : MacPromptsCard.overContentHeightFraction
        let beside = fitsBeside
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGSize.self) { geometry in
                let size = geometry.size
                let preferred = beside ? full : max(minimum, size.width * widthFraction)
                let width = max(0, min(full, preferred, size.width - margin))
                return CGSize(width: width, height: max(120, size.height * heightFraction - 56))
            } action: {
                limits = $0
            }
            .overlay(alignment: .topTrailing) {
                if limits.width > 0 { content(limits) }
            }
    }
}

/// The pane's Your prompts card (design: Prompts card). It floats at the
/// pane's top trailing corner: beside the conversation when the pane has
/// room (the pane shifts the conversation aside by `reserve`), over it in
/// narrow panes, where it starts collapsed into the circular bubble button
/// at the same corner.
/// Only its own surface collapses it (header, count, collapse button, a
/// terminal prompt row and, over content, the footer). A click outside it —
/// in this pane or in another split pane — never closes it and never changes
/// another session's card (owner correction 2026-11-15).
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
    /// Fixed footer: return the pane to the latest position (owner 2026-10-25,
    /// pinned to the bottom 2026-10-31).
    var onJumpLatest: () -> Void = {}

    static let width: CGFloat = 300
    /// Identity of the fixed footer row, which is not a prompt.
    static let latestRowID = "corral-prompts-latest"
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
    @State private var hoveredLatest = false
    @State private var currentID: RichMessage.ID?

    var body: some View {
        // Collapsed, only the circular bubble button shows (owned by the
        // pane); the card itself renders nothing.
        Group {
            if isOpen {
                card
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
            }
        }
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
                    guard !Task.isCancelled, let lastID = prompts.last?.id else { return }
                    // The latest row is a fixed footer outside the scroll view,
                    // so anchor the newest prompt at the bottom instead.
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            // Fixed footer: returns to the latest message, never scrolls away.
            VStack(spacing: 0) {
                Divider()
                    .opacity(0.4)
                latestRow
                    .id(Self.latestRowID)
                    .interfacePadding(Self.rowInset)
            }
        }
        .frame(width: width)
        .background {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius * interfaceScale, style: .continuous)
            shape.fill(onTerminal ? Color(nsColor: TerminalAppearance.background) : Color(.systemGroupedBackground))
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.045))
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
            .accessibilityIdentifier("corral.prompts.hide")
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

    /// Fixed footer: returns the pane to the latest position, never to a
    /// prompt (owner requirement 2026-10-25). The card stays open in both
    /// presentations (owner correction 2026-11-15): jumping is not a
    /// dismissal, so a floating card no longer closes first.
    private var latestRow: some View {
        Button {
            onJumpLatest()
        } label: {
            HStack(spacing: Space.sm * interfaceScale) {
                Image(systemName: "arrow.down.to.line.compact")
                    .interfaceFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("session.detail.user_prompts.jump_latest")
                    .interfaceFont(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .interfacePadding(.horizontal, Space.sm + 2)
            .interfacePadding(.vertical, overContent ? 5 : 7)
            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hoveredLatest ? 0.06 : 0), in: rowShape)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("corral.prompt.latest")
        .help(Text("session.detail.user_prompts.jump_latest"))
        .onHover { hoveredLatest = $0 }
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
