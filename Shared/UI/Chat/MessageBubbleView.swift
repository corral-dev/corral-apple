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
        // The app's window, never the physical screen: a folding iPhone or a
        // resized window is smaller than its display.
        if let height = scenes.first?.coordinateSpace.bounds.height, height > 1 {
            return height
        }
        return 800
        #endif
    }

    static func maxTextHeight(screenHeight: CGFloat = screenHeight()) -> CGFloat {
        max(screenHeight * maxHeightFraction - bubbleVerticalPadding, minTextHeight)
    }

    /// Default overlong-bubble cap: live half-screen on iOS, uncapped on Mac.
    /// ChatView passes a per-evaluation value so rotation re-evaluates capped
    /// rows; direct constructions (tests, previews) use this live default.
    static var defaultBubbleCap: CGFloat? {
        #if os(macOS)
        // Desktop-first (owner requirement 2026-10-04): messages show at full
        // height and the conversation scrolls, as in the TUI preview.
        return nil
        #else
        return maxTextHeight()
        #endif
    }
}

#if DEBUG
/// Warm-switch diagnostics: do Equatable rows actually skip body evaluation
/// when their inputs are unchanged? Reset per inspected switch.
enum SwitchBodyCounters {
    nonisolated(unsafe) static var bubbleBodies = 0
    nonisolated(unsafe) static var toolBodies = 0
    static func reset() {
        bubbleBodies = 0
        toolBodies = 0
    }
}
#endif

struct MessageBubbleView: View, Equatable {
    let message: RichMessage
    var runtimeID: String? = nil
    var onRetry: (() -> Void)? = nil
    /// Explicit style inputs instead of environment: row equality must cover
    /// every dynamic input, or a pruned row would keep stale zoom/theme text.
    /// Callers pass the live values; previews/tests use the same defaults the
    /// environment would provide.
    var interfaceScale: CGFloat = 1
    var sessionTextScale: CGFloat = SessionTextSize.default.scale
    var colorScheme: ColorScheme = .light
    /// Height cap for overlong bubbles (live screen on iOS, nil on the Mac).
    /// Explicit so rotation re-evaluates capped rows; defaults to the live cap.
    var bubbleTextCap: CGFloat? = MessageBubbleLayout.defaultBubbleCap
    /// Identity of the retained text network backing this row (Mac only, nil
    /// elsewhere). A replaced network must re-resolve even when the messages
    /// are identical.
    var selectionDocumentID: ObjectIdentifier? = nil
    var mediaRevision: Int = 0
    @Environment(\.chatImageLoader) private var imageLoader

    /// `onRetry` is excluded: its behavior is fully determined by `message`.
    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message == rhs.message
            && lhs.runtimeID == rhs.runtimeID
            && lhs.interfaceScale == rhs.interfaceScale
            && lhs.sessionTextScale == rhs.sessionTextScale
            && lhs.colorScheme == rhs.colorScheme
            && lhs.bubbleTextCap == rhs.bubbleTextCap
            && lhs.selectionDocumentID == rhs.selectionDocumentID
            && lhs.mediaRevision == rhs.mediaRevision
    }

    /// Capped text still has hidden lines below its fade.
    @State private var hasMoreBelow = false
    #if os(macOS)
    @State private var hovering = false
    @State private var copied = false
    #endif

    private var isUser: Bool { message.role.lowercased() == "user" }
    private var isFailedUser: Bool {
        isUser && (message.delivery == .failed || message.delivery == .needsReview)
    }
    private var userForeground: Color {
        Palette.userBubbleForeground
    }

    var body: some View {
        #if DEBUG
        let _ = SwitchBodyCounters.bubbleBodies &+= 1
        #endif
        VStack(alignment: .trailing, spacing: Space.xs * interfaceScale) {
            HStack(alignment: .bottom, spacing: Space.sm * interfaceScale) {
                if isUser {
                    Spacer(minLength: userLeadingMinimum * interfaceScale)
                    #if os(macOS)
                    copySlot
                    #endif
                }
                messageBubble
                #if os(macOS)
                if !isUser { copySlot }
                #endif
            }
            #if os(macOS)
            .onHover { hovering = $0 }
            #endif
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

    /// One compact block under the bubble (owner correction 2026-10-11): it hugs the
    /// bubble's trailing edge, but its lines read left to right like a paragraph.
    /// Status and Retry share the first line; the cause hangs under the status.
    /// The block is capped to a readable measure so a short bubble does not
    /// leave a full-column cause paragraph beside it.
    private static let feedbackMaxWidth: CGFloat = 360

    private var deliveryFeedback: some View {
        let unconfirmed = message.delivery == .needsReview
        return HStack(alignment: .firstTextBaseline, spacing: Space.xs * interfaceScale) {
            Image(systemName: unconfirmed ? "questionmark.circle" : "exclamationmark.circle")
                .foregroundStyle(unconfirmed ? Color.secondary : Palette.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs / 2 * interfaceScale) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm * interfaceScale) {
                    Text(unconfirmed ? "chat.delivery.unconfirmed" : "chat.delivery.failed")
                        .foregroundStyle(unconfirmed ? Color.primary : Palette.danger)
                    if let onRetry {
                        Button(action: onRetry) {
                            Text(unconfirmed ? "chat.delivery.retry_check" : "chat.delivery.retry")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                        .modifier(CompactHitTarget())
                    }
                }
                .interfaceFont(.footnote.weight(.semibold))
                Text(verbatim: failureReason)
                    .interfaceFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }
        }
        .interfaceFont(.footnote)
        .interfaceFrame(maxWidth: Self.feedbackMaxWidth * interfaceScale, alignment: .trailing)
        .interfaceFrame(maxWidth: .infinity, alignment: .trailing)
        .interfacePadding(.leading, Space.xxl)
    }

    @ViewBuilder
    private var messageBubble: some View {
        if let text = message.text, !text.allSatisfy(\.isWhitespace) {
            VStack(alignment: isUser ? .trailing : .leading, spacing: Space.sm * interfaceScale) {
                SelectableAttributedText(
                    attributed: message.seq > 0
                        ? (imageLoader?.rendered(text: text, dark: colorScheme == .dark, seq: message.seq) ?? ChatMarkdown.attributed(text))
                        : ChatMarkdown.attributed(text),
                    foreground: isUser ? userForeground : Color.primary,
                    // Match links and selection handles to the bubble's contrast pair.
                    tint: isUser ? userForeground : Palette.accent,
                    fontStyle: .bubbleBody,
                    maxHeight: bubbleTextCap,
                    onMoreBelowChange: { hasMoreBelow = $0 },
                    sourceMarkdown: text
                )
                #if os(macOS)
                .environment(\.macMessageSelectionID, message.seq)
                #endif
                .overlay(alignment: .bottom) {
                    if hasMoreBelow { scrollMoreHint }
                }
                // Bare path mentions keep the tile row; explicit Markdown images
                // are inline attachments at their own position in the text.
                if message.seq > 0 {
                    let images = ChatImageReferenceCache.references(in: text).filter { $0.kind == .mention }
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
            .task(id: "\(imageLoader.map(ObjectIdentifier.init).map(String.init(describing:)) ?? "")|\(colorScheme)|\(text)") {
                await imageLoader?.diagrams.prepare(text: text, dark: colorScheme == .dark)
                if message.seq > 0 {
                    await imageLoader?.prepareImages(in: text, seq: message.seq)
                }
            }
        }
    }

    /// Leading room a user bubble keeps free. On the Mac the copy slot sits in
    /// that room, so the bubble's widest size is unchanged.
    private var userLeadingMinimum: CGFloat {
        #if os(macOS)
        max(0, Space.xxl - TouchTarget.iconVisual - Space.sm)
        #else
        Space.xxl
        #endif
    }

    #if os(macOS)
    /// Hover copy (owner request 2026-11-08): copies the message's original
    /// Markdown. It follows the pane title's hover buttons: a borderless 24 pt
    /// secondary icon in a slot that is always laid out and only fades in, so
    /// hovering never moves text. The slot sits beside the message on its open
    /// side (left of a user bubble, right of assistant text), bottom-aligned
    /// where reading ends; it never covers text.
    @ViewBuilder
    private var copySlot: some View {
        if let source = message.text, !source.allSatisfy(\.isWhitespace) {
            Button {
                PlatformPasteboard.copy(source)
                copied = true
                AccessibilityNotification.Announcement(String(localized: "chat.copied")).post()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .interfaceFont(.system(size: 11, weight: .semibold))
                    .interfaceFrame(width: TouchTarget.iconVisual, height: TouchTarget.iconVisual)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.secondary)
            .help(Text(copied ? "chat.copied" : "chat.copy_markdown"))
            .accessibilityLabel(Text("chat.copy_markdown"))
            .opacity(copyVisible ? 1 : 0)
            .allowsHitTesting(copyVisible)
            .accessibilityHidden(!copyVisible)
            .animation(MacMotion.state, value: copyVisible)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }

    private var copyVisible: Bool {
        hovering || copied || MessageCopyInspection.alwaysVisible
    }
    #endif

    /// Sits on the bottom fade: more text scrolls inside this bubble. Hint only —
    /// never intercepts the inner scroll or text selection.
    private var scrollMoreHint: some View {
        Image(systemName: "chevron.down")
            .interfaceFont(.footnote.weight(.bold))
            .foregroundStyle(isUser ? userForeground.opacity(0.9) : Color.secondary)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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

/// A 44-point hit area around a text-sized control without adding layout height,
/// so the cause stays directly below the status line.
private struct CompactHitTarget: ViewModifier {
    func body(content: Content) -> some View {
        let slop = Space.md
        content
            .interfacePadding(slop)
            .contentShape(Rectangle())
            .interfacePadding(-slop)
    }
}

#if os(macOS)
/// Debug-only `-CorralInspectMessageCopy`: show every hover copy slot so a
/// window capture can inspect it without driving the pointer.
enum MessageCopyInspection {
    static let alwaysVisible: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-CorralInspectMessageCopy")
        #else
        false
        #endif
    }()
}
#endif
