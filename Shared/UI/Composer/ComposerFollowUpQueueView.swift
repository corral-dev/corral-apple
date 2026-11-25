import SwiftUI

struct ComposerFollowUpQueueView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.composerRecedes) private var recedes

    let queue: SessionFollowUpQueue
    let onSendNow: (FollowUpItem) -> Void
    let onEdit: (FollowUpItem) -> Void
    let onRemove: (FollowUpItem) -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onClear: () -> Void

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.lg * interfaceScale, style: .continuous)
    }

    private var rowHeight: CGFloat {
        #if os(iOS)
        40 * interfaceScale
        #else
        32 * interfaceScale
        #endif
    }

    private var buttonSize: CGFloat {
        #if os(iOS)
        32 * interfaceScale
        #else
        24 * interfaceScale
        #endif
    }

    private var maxVisibleRows: Int { 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.45)
            rowList
        }
        .background {
            if reduceTransparency {
                cardShape.fill(Color(.secondarySystemGroupedBackground))
            } else {
                cardShape.fill(.regularMaterial)
            }
        }
        .overlay(cardShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .opacity(recedes ? 0.5 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.followup.queue")
        .chatReadableColumn()
        .interfacePadding(.horizontal, Space.base)
        .interfacePadding(.top, Space.xs)
    }

    private var header: some View {
        HStack(spacing: Space.sm * interfaceScale) {
            Image(systemName: headerIconName)
                .interfaceFont(.caption.weight(.semibold))
                .foregroundStyle(headerIconColor)

            Text(headerTitleKey)
                .interfaceFont(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if queue.count > 1 {
                Text(verbatim: "· \(queue.count)")
                    .interfaceFont(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if queue.isPaused {
                Button(action: onResume) {
                    HStack(spacing: 4 * interfaceScale) {
                        Image(systemName: "play.fill")
                        Text("composer.followup.resume")
                    }
                    .interfaceFont(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.accent)
                .accessibilityIdentifier("composer.followup.resume")
            } else {
                Button(action: onPause) {
                    HStack(spacing: 4 * interfaceScale) {
                        Image(systemName: "pause.fill")
                        Text("composer.followup.pause")
                    }
                    .interfaceFont(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("composer.followup.pause")
            }

            if queue.count > 1 {
                Button(action: onClear) {
                    Text("composer.followup.clear")
                        .interfaceFont(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("composer.followup.clear")
            }
        }
        .interfacePadding(.horizontal, Space.md)
        .interfacePadding(.vertical, Space.sm)
    }

    @ViewBuilder
    private var rowList: some View {
        if queue.count > maxVisibleRows {
            ScrollView(.vertical, showsIndicators: true) {
                rowsStack
            }
            .frame(height: rowHeight * CGFloat(maxVisibleRows))
        } else {
            rowsStack
        }
    }

    private var rowsStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().opacity(0.35)
                }
                row(item, index: index)
            }
        }
    }

    private func row(_ item: FollowUpItem, index: Int) -> some View {
        let baseRow = HStack(spacing: Space.sm * interfaceScale) {
            Group {
                if item.isSending {
                    ProgressView()
                        .controlSize(.mini)
                } else if item.failureMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .interfaceFont(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.danger)
                } else {
                    Text(verbatim: "\(index + 1)")
                        .interfaceFont(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16 * interfaceScale, alignment: .center)

            Text(displaySummary(for: item))
                .interfaceFont(.subheadline)
                .foregroundStyle(item.failureMessage != nil ? Palette.danger : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.attachmentCount > 0 && !item.text.isEmpty {
                HStack(spacing: 2 * interfaceScale) {
                    Image(systemName: "paperclip")
                    Text(verbatim: "\(item.attachmentCount)")
                }
                .interfaceFont(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: Space.xs * interfaceScale) {
                rowActionButton(
                    systemImage: "arrow.up.circle.fill",
                    label: "composer.followup.send_now",
                    identifier: "composer.followup.send_now",
                    disabled: item.isSending
                ) {
                    onSendNow(item)
                }

                rowActionButton(
                    systemImage: "pencil",
                    label: "composer.followup.edit",
                    identifier: "composer.followup.edit",
                    disabled: item.isSending
                ) {
                    onEdit(item)
                }

                rowActionButton(
                    systemImage: "xmark",
                    label: "composer.followup.remove",
                    identifier: "composer.followup.remove",
                    disabled: item.isSending
                ) {
                    onRemove(item)
                }
            }
        }
        .frame(height: rowHeight)
        .interfacePadding(.horizontal, Space.md)

        #if os(macOS)
        return baseRow.help(item.failureMessage ?? "")
        #else
        return baseRow
        #endif
    }

    private func rowActionButton(
        systemImage: String,
        label: LocalizedStringKey,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .interfaceFont(.caption.weight(.semibold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : Color.secondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
        #if os(macOS)
        .help(Text(label))
        #endif
    }

    private var headerIconName: String {
        if queue.hasFailedItem { return "exclamationmark.triangle.fill" }
        if queue.isPaused { return "pause.circle.fill" }
        return "clock.arrow.circlepath"
    }

    private var headerIconColor: Color {
        if queue.hasFailedItem { return Palette.danger }
        if queue.isPaused { return .secondary }
        return Palette.accent
    }

    private var headerTitleKey: LocalizedStringKey {
        if queue.hasFailedItem { return "composer.followup.failed" }
        if queue.isPaused { return "composer.followup.paused" }
        return "composer.followup.header"
    }

    private func displaySummary(for item: FollowUpItem) -> String {
        if !item.text.isEmpty {
            return item.text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        return String(localized: "composer.followup.attachments_only \(item.attachmentCount)")
    }
}
