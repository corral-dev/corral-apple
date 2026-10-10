import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Overlong-bubble policy: cap at 50% of screen height and scroll inner text
/// instead of occupying the whole timeline. Never wrap the bubble in a
/// GeometryReader — that expands short user bubbles to fill the row.
enum MessageBubbleLayout {
    static let maxHeightFraction: CGFloat = 0.5
    /// Shared with the visible bubble so the height cap includes both insets.
    static let bubbleVerticalPadding: CGFloat = Space.md * 2
    static let minTextHeight: CGFloat = 44

    static func screenHeight() -> CGFloat {
        #if os(macOS)
        // The Mac caps against the key window's content height (the window is the "screen").
        if let height = NSApp.keyWindow?.contentLayoutRect.height, height > 1 { return height }
        return NSScreen.main?.visibleFrame.height ?? 800
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let height = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.bounds.height,
           height > 1 {
            return height
        }
        if let height = scenes.first?.screen.bounds.height, height > 1 {
            return height
        }
        return UIScreen.main.bounds.height
        #endif
    }

    static func maxTextHeight(screenHeight: CGFloat = screenHeight()) -> CGFloat {
        max(screenHeight * maxHeightFraction - bubbleVerticalPadding, minTextHeight)
    }
}

struct MessageBubbleView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let message: RichMessage
    var runtimeID: String? = nil
    var onRetry: (() -> Void)? = nil

    /// Capped text still has hidden lines below its fade.
    @State private var hasMoreBelow = false

    private var isUser: Bool { message.role.lowercased() == "user" }
    private var isFailedUser: Bool {
        isUser && (message.delivery == .failed || message.delivery == .needsReview)
    }
    private var isInFlightUser: Bool {
        isUser && (message.delivery == .pending || message.delivery == .accepted)
    }
    private var userForeground: Color {
        Palette.userBubbleForeground
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs * interfaceScale) {
            HStack(alignment: .bottom, spacing: Space.sm * interfaceScale) {
                if isUser {
                    Spacer(minLength: Space.xxl * interfaceScale)
                }
                messageBubble
                    .opacity(isInFlightUser ? 0.7 : 1)
            }
            if isFailedUser {
                deliveryFeedback
            }
        }
    }

    private var failureReason: String {
        let detail = message.failureDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty { return detail }
        return String(localized: String.LocalizationValue(
            message.delivery == .needsReview ? "chat.delivery.unknown" : "chat.delivery.no_reason"
        ))
    }

    private var deliveryFeedback: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: Space.sm * interfaceScale) {
                Label(message.delivery == .needsReview
                      ? "chat.delivery.unconfirmed" : "chat.delivery.failed",
                      systemImage: message.delivery == .needsReview
                      ? "questionmark.circle" : "exclamationmark.circle")
                    .interfaceFont(.caption.weight(.medium))
                    .foregroundStyle(message.delivery == .needsReview ? Color.secondary : Palette.danger)
                if let onRetry {
                    Button(action: onRetry) {
                        Text(message.delivery == .needsReview
                             ? "chat.delivery.retry_check" : "chat.delivery.retry")
                            .interfaceFont(.footnote.weight(.medium))
                            .interfaceFrame(minHeight: TouchTarget.minimum)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                }
            }
            Text(verbatim: failureReason)
                .interfaceFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)

        }
        .interfaceFrame(maxWidth: .infinity, alignment: .trailing)
        .interfacePadding(.leading, Space.xxl)
    }

    @ViewBuilder
    private var messageBubble: some View {
        if let text = message.text, !text.allSatisfy(\.isWhitespace) {
            VStack(alignment: isUser ? .trailing : .leading, spacing: Space.sm * interfaceScale) {
                SelectableAttributedText(
                    attributed: ChatMarkdown.attributed(text),
                    foreground: isUser ? userForeground : Color.primary,
                    // Match links and selection handles to the bubble's contrast pair.
                    tint: isUser ? userForeground : Palette.accent,
                    fontStyle: .bubbleBody,
                    maxHeight: bubbleTextCap,
                    onMoreBelowChange: { hasMoreBelow = $0 }
                )
                #if os(macOS)
                .environment(\.macMessageSelectionID, message.seq)
                #endif
                .overlay(alignment: .bottom) {
                    if hasMoreBelow { scrollMoreHint }
                }
                // Host previews need the official seq; local echoes wait for it.
                if message.seq > 0 {
                    let images = ChatImageReferenceCache.references(in: text)
                    if !images.isEmpty {
                        MessageImagesView(
                            seq: message.seq, references: images, isUser: isUser,
                            userForeground: userForeground
                        )
                    }
                }
            }
            .interfacePadding(.horizontal, hasBubble ? Space.base : 0)
            .interfacePadding(.vertical, hasBubble ? MessageBubbleLayout.bubbleVerticalPadding / 2 : Space.xs)
            // 助手铺满内容区；页边距由对话列表的 Space.base 承担，不要再卡死宽度。
            .frame(
                maxWidth: isUser ? nil : .infinity,
                alignment: isUser ? .trailing : .leading
            )
            .background(hasBubble ? bubbleFill : Color.clear, in: bubbleShape)
        }
    }

    /// Sits on the bottom fade: more text scrolls inside this bubble. Hint only —
    /// never intercepts the inner scroll or text selection.
    private var scrollMoreHint: some View {
        Image(systemName: "chevron.down")
            .interfaceFont(.footnote.weight(.bold))
            .foregroundStyle(isUser ? userForeground.opacity(0.9) : Color.secondary)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// iOS caps long bubbles at half the screen (owner decision); the Mac does not cap.
    private var bubbleTextCap: CGFloat? {
        #if os(macOS)
        // Desktop-first (owner requirement 2026-10-04): messages show at full
        // height and the conversation scrolls, as in the TUI preview.
        return nil
        #else
        return MessageBubbleLayout.maxTextHeight()
        #endif
    }

    /// User messages always sit in a bubble; assistant text is bubble-free on the Mac.
    private var hasBubble: Bool { isUser || ChatLayout.assistantUsesBubble }

    private var bubbleFill: Color {
        if isUser {
            Palette.userBubble
        } else {
            Palette.assistantBubble
        }
    }

    /// A tail belongs to a bubble that hugs its text. The assistant surface spans the
    /// whole column, so it keeps even corners and only the user bubble points home.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Radius.bubble * interfaceScale,
            bottomLeadingRadius: Radius.bubble * interfaceScale,
            bottomTrailingRadius: (isUser ? Radius.bubbleTail : Radius.bubble) * interfaceScale,
            topTrailingRadius: Radius.bubble * interfaceScale,
            style: .continuous
        )
    }
}
