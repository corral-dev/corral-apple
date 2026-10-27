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

/// Inputs of the question card; also the Mac table's row value for it.
struct ChatPromptsCardState: Equatable {
    var prompts: [SessionPrompt]
    var isConnected: Bool
    var isSending: Bool
    var showsBlockedHint: Bool
    var submissionState: NativeQuestionSubmissionState?
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
    /// Native tables need exact row heights. Cold open measures only this tail,
    /// even when a terminal-only session has accumulated hundreds of turns.
    @State private var macHistoryStartID: String?
    private let macInitialItemCount = 12

    private var macVisibleItems: [ConversationTimelineItem] {
        let items = store.timelineItems
        if let id = macHistoryStartID, let start = items.firstIndex(where: { $0.id == id }) {
            return Array(items[start...])
        }
        return Array(items[macPageStart(in: items, before: items.count)...])
    }

    private func macPageStart(in items: [ConversationTimelineItem], before end: Int) -> Int {
        // A few very long replies cost more than many short messages. Bound
        // both row count and text work for initial paint and upward reading.
        var start = end
        var bytes = 0
        for index in (0..<end).reversed().prefix(macInitialItemCount) {
            let cost: Int
            if case .message(let message) = items[index] {
                cost = message.text?.utf8.count ?? 0
            } else {
                cost = 256
            }
            if start < end - 1, bytes + cost > 4_096 { break }
            bytes += cost
            start = index
        }
        return start
    }

    private var macHasHiddenHistory: Bool {
        macVisibleItems.count < store.timelineItems.count
    }

    private func macLoadEarlier() async -> Bool {
        let items = store.timelineItems
        if let first = macVisibleItems.first, let start = items.firstIndex(where: { $0.id == first.id }), start > 0 {
            macHistoryStartID = items[macPageStart(in: items, before: start)].id
            return true
        }
        let firstID = macVisibleItems.first?.id
        let oldest = store.oldestSequence
        await store.loadEarlier()
        let updated = store.timelineItems
        if let firstID, let start = updated.firstIndex(where: { $0.id == firstID }) {
            macHistoryStartID = updated[macPageStart(in: updated, before: start)].id
        }
        return store.oldestSequence < oldest
    }
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
    /// Request that refused a composer send: its card shows the quiet hint.
    var blockedQuestionRequestID: String? = nil
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
        blockedQuestionRequestID: String? = nil,
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
        self.blockedQuestionRequestID = blockedQuestionRequestID
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
        #if os(macOS)
        // Only widen the window: trimming rows above an already visible target
        // moves the reader once before the jump lands (a two-step jump).
        let items = store.timelineItems
        if let index = items.firstIndex(where: { $0.id == messageID }),
           let first = macVisibleItems.first,
           let start = items.firstIndex(where: { $0.id == first.id }),
           index - 1 < start {
            macHistoryStartID = items[max(0, index - 1)].id
        }
        #endif
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
        #if os(macOS)
        let items = macVisibleItems
        #else
        let items = store.timelineItems
        #endif
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let timeSeparators = ConversationTimePolicy.separators(
            for: items, messages: store.visibleMessages, calendar: localCalendar
        )
        let activity = activityState
        #if os(macOS)
        return macConversation(items: items, separators: timeSeparators, activity: activity)
            .modifier(MacConversationTextSelection(
                identity: ObjectIdentifier(store),
                messages: items.compactMap { item in
                    if case .message(let message) = item { return message }
                    return nil
                },
                documentOverride: textDocument,
                renderText: { imageLoader?.diagrams.attributed(text: $0, dark: colorScheme == .dark) ?? ChatMarkdown.attributed($0) },
                mediaRevisions: Dictionary(items.compactMap { item -> (Int, Int)? in
                    guard case .message(let message) = item else { return nil }
                    return (message.seq, mediaRevision(item))
                }, uniquingKeysWith: { _, latest in latest })
            ))
        #else
        // The activity cue renders below the question card, so it is the true bottom.
        let latestID: String? = activity != nil
            ? "activity"
            : (store.prompts.isEmpty ? items.last?.id : "prompts")
        return ChatScrollView(
            scrollToLatestRequest: scrollToLatestRequest + promptSubmission,
            latestID: latestID,
            scrollToMessageID: $revealedMessageID,
            onPullToLoadEarlier: store.hasMoreHistory ? {
                let oldest = store.oldestSequence
                await store.loadEarlier()
                return store.oldestSequence < oldest
            } : nil,
            pullProgress: $loadEarlierPullProgress,
            header: {
                if let loadError = store.loadError {
                    loadErrorLabel(loadError)
                }
                if store.hasMoreHistory {
                    ChatLoadEarlierButton(
                        pullProgress: loadEarlierPullProgress,
                        isLoading: store.isLoadingHistory
                    ) {
                        historyRequested = true
                    }
                }
            }
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                timelineRow(item, separator: timeSeparators[item.id],
                            gap: ChatTimelineRhythm.leadingGap(before: index, in: items))
                    .id(item.id)
            }

            if !store.prompts.isEmpty {
                promptsCard(promptsState)
                    .id("prompts")
            }

            // 运行中跳动小点：只在有正文时间线底部出现，loading/空态不长条；顶栏不再重复运行状态。
            if let activity {
                activityRow(activity)
                    .id("activity")
            }
        }
        #endif
    }

    private func loadErrorLabel(_ loadError: String) -> some View {
        Label(loadError, systemImage: "exclamationmark.triangle")
            .interfaceFont(.footnote)
            .foregroundStyle(.secondary)
            .interfaceFrame(maxWidth: .infinity)
    }

    @Environment(\.chatImageLoader) private var imageLoader

    private func mediaRevision(_ item: ConversationTimelineItem) -> Int {
        guard case .message(let message) = item, let text = message.text else { return 0 }
        return imageLoader?.diagrams.revision(text: text, dark: colorScheme == .dark) ?? 0
    }

    private func timelineRow(_ item: ConversationTimelineItem, separator: Date?, gap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let separator {
                ChatTimeSeparator(date: separator)
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
                    selectionDocumentID: textDocumentID,
                    mediaRevision: mediaRevision(item)
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
        .interfacePadding(.top, gap)
    }

    private var promptsState: ChatPromptsCardState {
        ChatPromptsCardState(
            prompts: store.prompts, isConnected: isConnected, isSending: isSending,
            showsBlockedHint: showsBlockedHint, submissionState: store.questionSubmissionState
        )
    }

    private func promptsCard(_ state: ChatPromptsCardState) -> some View {
        AnswerOptionsView(
            prompts: state.prompts,
            isConnected: state.isConnected,
            isBusy: state.isSending,
            showsBlockedHint: state.showsBlockedHint,
            submissionState: state.submissionState,
            onSubmit: submitQuestion
        )
    }

    private func activityRow(_ activity: ChatActivityState) -> some View {
        ChatActivityFooter(state: activity)
            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            .interfacePadding(.top, Space.xs)
    }

    #if os(macOS)
    /// Rows in reading order, with every input that changes their rendering.
    private func macRows(items: [ConversationTimelineItem], separators: [String: Date],
                         activity: ChatActivityState?) -> [MacConversationRow] {
        var rows: [MacConversationRow] = []
        rows.reserveCapacity(items.count + 4)
        if let loadError = store.loadError {
            rows.append(MacConversationRow(id: "load-error", value: .loadError(loadError)))
        }
        if macHasHiddenHistory || store.hasMoreHistory {
            // Owner correction 2026-10-11: no Load earlier control on the Mac.
            // Reaching the top loads by itself; the reserved row only shows
            // progress and keeps its height so nothing shifts.
            rows.append(MacConversationRow(id: "earlier-history",
                                           value: .earlierHistory(isLoading: store.isLoadingHistory)))
        }
        for (index, item) in items.enumerated() {
            rows.append(MacConversationRow(id: item.id, value: .timeline(
                item, separator: separators[item.id],
                gap: ChatTimelineRhythm.leadingGap(before: index, in: items)
            ), mediaRevision: mediaRevision(item)))
        }
        if !store.prompts.isEmpty {
            rows.append(MacConversationRow(id: "prompts", value: .prompts(promptsState)))
        }
        if let activity {
            rows.append(MacConversationRow(id: "activity", value: .activity(activity)))
        }
        return rows
    }

    @ViewBuilder
    private func macRowContent(_ row: MacConversationRow) -> some View {
        switch row.value {
        case .loadError(let message):
            loadErrorLabel(message)
        case .earlierHistory(let isLoading):
            ChatEarlierHistoryProgress(isLoading: isLoading)
        case .timeline(let item, let separator, let gap):
            timelineRow(item, separator: separator, gap: gap)
        case .prompts(let state):
            promptsCard(state)
        case .activity(let activity):
            activityRow(activity)
        }
    }

    private func macConversation(items: [ConversationTimelineItem], separators: [String: Date],
                                 activity: ChatActivityState?) -> some View {
        MacConversationScroller(
            rows: macRows(items: items, separators: separators, activity: activity),
            renderKey: MacConversationRenderKey(
                interfaceScale: interfaceScale, sessionTextScale: sessionTextScale,
                colorScheme: colorScheme, runtimeID: runtimeID, document: textDocumentID,
                imageLoader: imageLoader.map(ObjectIdentifier.init), mediaAvailable: imageLoader?.isAvailable == true
            ),
            rowContent: { AnyView(macRowContent($0)) },
            scrollToLatestRequest: scrollToLatestRequest + promptSubmission,
            scrollToMessageID: $revealedMessageID,
            onLoadEarlier: macHasHiddenHistory || store.hasMoreHistory ? {
                await macLoadEarlier()
            } : nil,
            onFollowChange: { follows in
                if !follows, macHistoryStartID == nil {
                    macHistoryStartID = macVisibleItems.first?.id
                }
            }
        )
    }
    #endif

    /// 对话流底部的安静提示。loading 与空态走别的分支，这里只处理 messageList。
    private var activityState: ChatActivityState? {
        ChatActivityState.resolve(store: store, connected: isConnected, marker: sessionMarker)
    }

    /// The refused send targets the currently open request; any other value
    /// (including a cleared request) hides the hint without extra state.
    private var showsBlockedHint: Bool {
        guard let blocked = blockedQuestionRequestID,
              let current = store.prompts.first?.requestID
        else { return false }
        return blocked == current
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
