import SwiftUI

/// The pane's Your prompts card (design: Prompts card). It floats at the
/// pane's top trailing corner: beside the conversation when the pane has
/// room (the pane shifts the conversation aside by `reserve`), over it in
/// narrow panes, where it starts collapsed into the pane header's button.
struct MacPromptsCard: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let prompts: [RichMessage]
    @Binding var isOpen: Bool
    var width: CGFloat = MacPromptsCard.width
    /// Floating over content in a narrow pane rather than beside it.
    var overContent = false
    var onTerminal = false
    var maxListHeight: CGFloat = 360
    var onSelect: (RichMessage) -> Void = { _ in }

    static let width: CGFloat = 300
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

    var body: some View {
        // Collapsed, the card lives in the pane header (prompts button), so
        // nothing floats over the conversation (design: Visual guidance pass).
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
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius * interfaceScale, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(overContent ? 0.10 : 0.06), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius * interfaceScale, style: .continuous))
        // Native row buttons own chat jumps; the remaining card surface closes.
        .onTapGesture { setOpen(false) }
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
    }

    private func row(_ prompt: RichMessage) -> some View {
        Button {
            currentID = prompt.id
            onSelect(prompt)
            if onTerminal { setOpen(false) }
        } label: {
            VStack(alignment: .leading, spacing: 2 * interfaceScale) {
                if let stamp = Self.timeLabel(prompt) {
                    Text(verbatim: stamp)
                        .interfaceFont(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: Self.oneLine(prompt))
                    .interfaceFont(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .interfacePadding(.horizontal, Space.sm + 2)
            .interfacePadding(.vertical, 7)
            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill(prompt.id), in: rowShape)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredID = prompt.id } else if hoveredID == prompt.id { hoveredID = nil }
        }
        .help(Text("mac.prompts.jump"))
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
