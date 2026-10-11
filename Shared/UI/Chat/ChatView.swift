import SwiftUI

/// Vertical rhythm of the conversation: a speaker's consecutive items stay grouped,
/// and handing over to the other speaker opens the largest gap. The scroll stack
/// contributes `Space.xs`, so these values are the extra distance on top of it.
enum ChatTimelineRhythm {
    static func leadingGap(
        before index: Int,
        in items: [ConversationTimelineItem]
    ) -> CGFloat {
        guard index > 0, index < items.count else { return 0 }
        switch (items[index - 1], items[index]) {
        case (.message(let previous), .message(let current)):
            return isSameSpeaker(previous, current) ? 0 : Space.sm
        case (.toolGroup, .toolGroup):
            return 0
        default:
            return Space.xs
        }
    }

    private static func isSameSpeaker(_ lhs: RichMessage, _ rhs: RichMessage) -> Bool {
        normalizedRole(lhs) == normalizedRole(rhs)
    }

    private static func normalizedRole(_ message: RichMessage) -> String {
        message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ChatView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.sessionTextScale) private var sessionTextScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Bindable var store: ConversationStore
    var runtimeID: String? = nil
    /// Retained native text network from the Mac pane cache (nil outside Mac
    /// panes, where the selection modifier owns a private document).
    #if os(macOS)
    @Environment(\.macConversationTextDocument) private var textDocument
    #endif
    /// Host-decided activity dot (waiting/working/recent); the activity footer
    /// follows it. Red unread is an independent overlay and never passed here.
    var sessionMarker: SessionPresentation.StatusMarker? = nil
    var isConnected = true
    var isSending = false
    var scrollToLatestRequest = 0
    /// 下拉进度（0..1）：ChatScrollView 经 Binding 回传，header 进度环用。
    /// nil = 未触碰（只显示箭头）；加载中由 isLoading 接管，不叠进度环。
    @Binding var loadEarlierPullProgress: Double?
    @State private var historyRequested = false
    @State private var promptSubmission = 0
    /// Outside jump requests (Your prompts) may target rows not loaded yet.
    @Binding var scrollToMessageID: String?
    /// The same request once its row is loaded; the scroll view consumes it.
    @State private var revealedMessageID: String?
    var onQuestionSubmit: ((String, [NativeQuestionAnswer]) -> Void)?
    var onRetryMessage: ((RichMessage) -> Void)?

    /// Identity of the retained Mac text network, for row equality. Nil
    /// outside Mac panes (and on iOS), where rows have no shared network.
    private var textDocumentID: ObjectIdentifier? {
#if os(macOS)
        textDocument.map(ObjectIdentifier.init)
#else
        nil
#endif
    }

    init(
        store: ConversationStore,
        runtimeID: String? = nil,
        sessionMarker: SessionPresentation.StatusMarker? = nil,
        isConnected: Bool = true,
        isSending: Bool = false,
        scrollToLatestRequest: Int = 0,
        loadEarlierPullProgress: Binding<Double?> = .constant(nil),
        scrollToMessageID: Binding<String?> = .constant(nil),
        onQuestionSubmit: ((String, [NativeQuestionAnswer]) -> Void)? = nil,
        onRetryMessage: ((RichMessage) -> Void)? = nil
    ) {
        self.store = store
        self.runtimeID = runtimeID
        self.sessionMarker = sessionMarker
        self.isConnected = isConnected
        self.isSending = isSending
        self.scrollToLatestRequest = scrollToLatestRequest
        self._loadEarlierPullProgress = loadEarlierPullProgress
        self._scrollToMessageID = scrollToMessageID
        self.onQuestionSubmit = onQuestionSubmit
        self.onRetryMessage = onRetryMessage
    }

    var body: some View {
        conversationBody
            .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .task(id: historyRequested) {
                guard historyRequested else { return }
                await store.loadEarlier()
                historyRequested = false
            }
            .onDisappear { historyRequested = false }
            .onChange(of: scrollToMessageID, initial: true) { _, messageID in
                guard let messageID else { return }
                scrollToMessageID = nil
                Task { await reveal(messageID) }
            }
    }

    /// Pages earlier until a requested message is loaded, then scrolls to it.
    private func reveal(_ messageID: String) async {
        let prefix = "message-"
        if !store.timelineItems.contains(where: { $0.id == messageID }),
           messageID.hasPrefix(prefix),
           let seq = Int(messageID.dropFirst(prefix.count)), seq > 0 {
            await store.loadEarlier(through: seq)
        }
        revealedMessageID = messageID
    }

    @ViewBuilder
    private var conversationBody: some View {
        Group {
            if let loadError = store.loadError, store.visibleMessages.isEmpty {
                ContentUnavailableView {
                    Label("chat.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("action.retry") {
                        Task { await store.retry() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isLoading, store.visibleMessages.isEmpty {
                ZStack {
                    ProgressView()
                }
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("chat.loading")
            } else if store.timelineItems.isEmpty, store.prompts.isEmpty {
                ContentUnavailableView {
                    Label("chat.empty.title", systemImage: "bubble.left")
                } description: {
                    Text("chat.empty.description")
                }
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messageList
            }
        }
    }

    private var messageList: some View {
        let items = store.timelineItems
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let timeSeparators = ConversationTimePolicy.separators(
            for: items, messages: store.visibleMessages, calendar: localCalendar
        )
        let activity = activityState
        // The activity cue renders below the question card, so it is the true bottom.
        let latestID: String? = activity != nil
            ? "activity"
            : (store.prompts.isEmpty ? items.last?.id : "prompts")
        return ChatScrollView(
            scrollToLatestRequest: scrollToLatestRequest + promptSubmission,
            latestID: latestID,
            scrollToMessageID: $revealedMessageID,
            jumpGlides: { target, visible in
                ChatJumpPlan.glides(in: store.timelineItems.map(\.id), target: target, visible: visible)
            },
            onPullToLoadEarlier: store.hasMoreHistory ? {
                let oldest = store.oldestSequence
                await store.loadEarlier()
                return store.oldestSequence < oldest
            } : nil,
            pullProgress: $loadEarlierPullProgress,
            header: {
                if let loadError = store.loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .interfaceFont(.footnote)
                        .foregroundStyle(.secondary)
                        .interfaceFrame(maxWidth: .infinity)
                }
                if store.hasMoreHistory {
                    #if os(macOS)
                    // Owner correction 2026-10-11: no Load earlier control on the
                    // Mac. Reaching the top loads by itself; the reserved row only
                    // shows progress and keeps its height so nothing shifts.
                    ChatEarlierHistoryProgress(isLoading: store.isLoadingHistory)
                    #else
                    ChatLoadEarlierButton(
                        pullProgress: loadEarlierPullProgress,
                        isLoading: store.isLoadingHistory
                    ) {
                        historyRequested = true
                    }
                    #endif
                }
            }
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 0) {
                    if let date = timeSeparators[item.id] {
                        ChatTimeSeparator(date: date)
                    }
                    switch item {
                    case .message(let message):
                        MessageBubbleView(
                            message: message,
                            runtimeID: runtimeID,
                            onRetry: { onRetryMessage?(message) },
                            interfaceScale: interfaceScale,
                            sessionTextScale: sessionTextScale,
                            colorScheme: colorScheme,
                            bubbleTextCap: MessageBubbleLayout.defaultBubbleCap,
                            selectionDocumentID: textDocumentID
                        )
                    case .toolGroup(_, let sourceSeqs, let tools):
                        ToolActivityView(
                            tools: tools,
                            sourceSeqs: sourceSeqs,
                            runtimeID: runtimeID,
                            onNeedDetails: { await store.fetchToolDetails(sourceSeqs: $0) },
                            detailSourceID: ObjectIdentifier(store),
                            interfaceScale: interfaceScale,
                            sessionTextScale: sessionTextScale,
                            colorScheme: colorScheme
                        )
                    }
                }
                .interfacePadding(.top, ChatTimelineRhythm.leadingGap(before: index, in: items))
                .id(item.id)
            }

            if !store.prompts.isEmpty {
                AnswerOptionsView(
                    prompts: store.prompts,
                    isConnected: isConnected,
                    isBusy: isSending,
                    submissionState: store.questionSubmissionState,
                    onSubmit: submitQuestion
                )
                .id("prompts")
            }

            // 运行中跳动小点：只在有正文时间线底部出现，loading/空态不长条；顶栏不再重复运行状态。
            if let activity {
                ChatActivityFooter(state: activity)
                    .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                    .interfacePadding(.top, Space.xs)
                    .id("activity")
            }
        }
        #if os(macOS)
        .modifier(MacConversationTextSelection(
            identity: ObjectIdentifier(store),
            messages: items.compactMap { item in
                if case .message(let message) = item { return message }
                return nil
            },
            documentOverride: textDocument
        ))
        #endif
    }

    /// 对话流底部的安静提示。loading 与空态走别的分支，这里只处理 messageList。
    private var activityState: ChatActivityState? {
        ChatActivityState.resolve(
            live: store.isLive,
            connected: isConnected,
            attention: store.displayAttention,
            hasPrompt: !store.prompts.isEmpty,
            hasRunningTool: hasRunningTool,
            marker: sessionMarker
        )
    }

    private var hasRunningTool: Bool {
        store.hasRunningTool
    }

    private func submitQuestion(_ requestID: String, answers: [NativeQuestionAnswer]) {
        guard isConnected, !isSending else { return }
        promptSubmission += 1
        if let onQuestionSubmit {
            onQuestionSubmit(requestID, answers)
        } else {
            Task { await store.submitQuestion(requestID: requestID, answers: answers) }
        }
    }
}

/// Quiet text control. Must not use the accent-tinted bordered capsule — that
/// reads as another user bubble and collides with the first message.
/// A stable icon slot avoids jumps; minimum height still permits Dynamic Type.
#if os(macOS)
/// Top row of a conversation with older history: empty at rest, a small
/// progress indicator while the next page loads.
private struct ChatEarlierHistoryProgress: View {
    var isLoading: Bool

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .interfaceControlSize(.small)
                    .transition(.opacity)
            }
        }
        .interfaceFrame(maxWidth: .infinity)
        .interfaceFrame(height: ChatLoadEarlierLayout.height)
        .accessibilityElement()
        .accessibilityLabel(isLoading ? Text("chat.loading_earlier") : Text(""))
        .accessibilityHidden(!isLoading)
    }
}
#endif

private struct ChatLoadEarlierButton: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = idle, 1 = release-to-load. Driven by the pull gesture; nil = tap button.
    var pullProgress: Double? = nil
    var isLoading: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs * interfaceScale) {
                loadIndicator
                    .interfaceFrame(width: 20, height: 20)
                    .animation(reduceMotion ? nil : .easeOut(duration: Motion.pressDuration), value: isLoading)
                    .accessibilityHidden(true)
                Text("chat.load_earlier")
                    .interfaceFont(.subheadline.weight(.medium))
            }
            .interfaceFrame(maxWidth: .infinity)
            .interfaceFrame(minHeight: ChatLoadEarlierLayout.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.secondary)
        .tint(.secondary)
        .disabled(isLoading)
        .accessibilityIdentifier("chat.load_earlier")
        .accessibilityValue(isLoading ? Text("chat.loading_earlier") : Text(""))

    }

    @ViewBuilder
    private var loadIndicator: some View {
        if isLoading {
            ProgressView()
                .interfaceControlSize(.small)
                .transition(.opacity)
        } else if let progress = pullProgress, progress > 0 {
            ZStack {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .interfacePadding(2)
            .transition(.opacity)
        } else {
            Image(systemName: "arrow.up")
                .interfaceFont(.subheadline.weight(.medium))
                .transition(.opacity)
        }
    }
}

/// Minimum hit area; the label may grow with accessibility text.
enum ChatLoadEarlierLayout {
    static let height: CGFloat = 44
}
