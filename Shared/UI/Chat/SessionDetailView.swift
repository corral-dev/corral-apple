import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SessionDetailView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fallbackSession: SessionSummary
    private let sessionKey: String
    private let metadataStore: SessionListStore?

    /// Resolves through the host-scoped metadata store so title-only events repaint
    /// the navigation header and prompt header while this detail is outside the list window.
    private var session: SessionSummary {
        guard let metadataStore else { return fallbackSession }
        // Touch the epoch so Observation invalidates this view on title-only merges.
        _ = metadataStore.metadataEpoch
        return metadataStore.session(for: sessionKey) ?? fallbackSession
    }

    init(
        session: SessionSummary,
        autoFocusComposer: Bool = false,
        metadataStore: SessionListStore? = nil,
        injectedStore: ConversationStore? = nil,
        composerFocusRequest: Int = 0,
        onComposerFocusChange: ((Bool) -> Void)? = nil,
        scrollRequest: ChatScrollRequest? = nil,
        onDidCreateSession: ((SessionSummary) -> Void)? = nil
    ) {
        self.injectedStore = injectedStore
        _conversationStore = State(initialValue: injectedStore)
        self.composerFocusRequest = composerFocusRequest
        self.onComposerFocusChange = onComposerFocusChange
        self.scrollRequest = scrollRequest
        fallbackSession = session
        sessionKey = session.key
        self.metadataStore = metadataStore
        self.autoFocusComposer = autoFocusComposer
        self.onDidCreateSession = onDidCreateSession
    }
    /// New-session path: focus the composer once after appear.
    var autoFocusComposer = false
    /// A conversation owned by the container (a Mac pane keeps it alive across
    /// chat/terminal switches and feeds its prompts panel). The container starts
    /// and stops it; this view only renders and sends through it.
    var injectedStore: ConversationStore? = nil
    /// Mac pane selection: non-zero moves the caret into this composer.
    var composerFocusRequest = 0
    var onComposerFocusChange: ((Bool) -> Void)? = nil
    /// Mac prompts panel: scroll the conversation to one message.
    var scrollRequest: ChatScrollRequest? = nil
    /// 复制/接力成功后的新会话：列表页负责落盘并推进，详情页只上报。
    var onDidCreateSession: ((SessionSummary) -> Void)? = nil
    @State private var pane: SessionDetailMode = .chat
    @State private var conversationStore: ConversationStore?
    @State private var imageLoader: ChatImageLoader?
    @State private var visitedTerminal = false
    @State private var draft = ""
    @State private var draftAttachments: [DraftImageAttachment] = []
    @State private var isSending = false
    @State private var isActionBusy = false
    @State private var isRestarting = false
    @State private var isInterrupting = false
    @State private var restartFailed = false
    @State private var runtimes: [RuntimeEntry] = []
    @State private var scrollToLatestRequest = 0
    @State private var loadEarlierPullProgress: Double?
    @State private var composerError: String?
    @State private var hapticScope = HapticScope()
    @State private var showUserPrompts = false
    @State private var showProjectTerminal = false
    @State private var scrollToMessageID: String?
    /// Request whose picker refused a composer send: its card shows the hint.
    @State private var blockedQuestionRequestID: String? = nil
    /// Prompt chosen in the Your prompts sheet, applied after the sheet closes.
    @State private var pendingPromptJump: String?
    @State private var draftHostID = ""
    @State private var didLoadDraft = false

    var body: some View {
        ChatScreen {
            detailContent
        } composer: {
            if pane == .chat || !canShowAgentTerminal { composerStack }
        }
        .background(Color(.systemGroupedBackground))
        .environment(\.sessionTextScale, appModel.sessionTextSize.scale)
        #if os(iOS)
        .navigationTitle(SessionPresentation.displayTitle(for: session))
        .inlineNavigationTitle()
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showUserPrompts = true
                } label: {
                    sessionHeaderLabel
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint(Text("session.detail.user_prompts.open_hint"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                actionsMenu
            }
        }
        .fullScreenCover(isPresented: $showProjectTerminal) {
            ProjectTerminalScreen(project: session.cwd)
        }
        #if DEBUG
        // `-CorralInspectProjectTerminal`: open the project terminal once the host allows it.
        .onChange(of: canOpenProjectTerminal, initial: true) { _, allowed in
            if allowed, ProcessInfo.processInfo.arguments.contains("-CorralInspectProjectTerminal") {
                showProjectTerminal = true
            }
        }
        #endif
        .sheet(isPresented: $showUserPrompts, onDismiss: {
            // Jump once the sheet is gone, so the glide is seen, not hidden behind it.
            guard let pendingPromptJump else { return }
            self.pendingPromptJump = nil
            scrollToMessageID = pendingPromptJump
        }) {
            UserPromptsView(
                prompts: userPrompts,
                onSelect: { message in
                    pendingPromptJump = ConversationTimelineItem.message(message).id
                }
            )
            .environment(\.sessionTextScale, appModel.sessionTextSize.scale)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled(false)
        }
        #endif
        // First frame must already show the cached tail and draft: build them
        // synchronously on appear, never behind a network call (open-jump fix).
        .onAppear {
            prepareConversationIfNeeded()
            // Red dot clears on tap; a Mac pane (injected store) does its own.
            if injectedStore == nil { metadataStore?.markReadLocally(key: sessionKey) }
        }
        .task {
            let conv = prepareConversationIfNeeded()
            async let runtimesLoad: Void = loadRuntimes()
            async let readMark: Void = injectedStore == nil ? conv.markRead() : ()
            async let chatStart: Void = startIfOwned(conv)
            await chatStart
            await runtimesLoad
            await readMark
#if DEBUG
            await inspectDeliveryIfRequested(conv)
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectFork"),
               ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == sessionKey {
                await copySession()
            }
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectForkSend"),
               ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == sessionKey {
                draft = "Reply exactly FORK_SYNC_OK."
                submitDraft(draft, [])
            }
#endif
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectLoadEarlier"),
               let firstID = conv.timelineItems.first?.id {
                scrollToMessageID = firstID
            }
        }
        .onChange(of: draft) { _, newValue in
            persistDraft(newValue)
        }
        .task(id: scrollRequest) {
            // A request made before this view existed (terminal → chat) waits
            // one frame for the timeline to lay out.
            guard let scrollRequest else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollToMessageID = scrollRequest.messageID
        }
        .onChange(of: pane) { _, newValue in
            if newValue == .terminal { visitedTerminal = true }
        }
        .onChange(of: canShowAgentTerminal) { _, allowed in
            if !allowed { pane = .chat }
        }
        #if DEBUG
        .onChange(of: canShowAgentTerminal, initial: true) { _, allowed in
            if allowed, ProcessInfo.processInfo.arguments.contains("-CorralInspectAgentTerminal") {
                visitedTerminal = true
                pane = .terminal
            }
        }
        #endif
        .hapticScope(hapticScope)
        .onDisappear {
            persistDraft(draft)
            let owned = injectedStore == nil ? conversationStore : nil
            Task {
                await owned?.stop()
            }
        }
    }


    #if os(iOS)
    /// Project terminal: a full pairing to a host that runs project shells.
    /// Independent of per-session agent terminal switching.
    private var canOpenProjectTerminal: Bool {
        appModel.client?.hostCapabilities.projectShell == true
            && !SessionActionsMenu.isReadonly(access: appModel.connectedAccess)
    }
    #endif

    private var actionsMenu: some View {
        SessionActionsMenuView(
            session: session,
            runtimes: runtimes,
            access: appModel.connectedAccess,
            clientReady: isHostReady,
            isBusy: isSending || isActionBusy,
            supportsRestart: appModel.client?.hostCapabilities.sessionRestart == true,
            onRestart: startRestart,
            onCopy: { Task { await copySession() } },
            onHandoff: { target in Task { await handoffSession(to: target) } },
            onOpenTerminal: openTerminalAction,
            displayMode: canShowAgentTerminal ? $pane : nil
        )
    }

    /// iPhone: the project terminal lives in this menu (the session page keeps
    /// only back and menu in its navigation bar). The Mac opens terminals as panes.
    private var openTerminalAction: (() -> Void)? {
        #if os(iOS)
        canOpenProjectTerminal ? { showProjectTerminal = true } : nil
        #else
        nil
        #endif
    }

    private func startIfOwned(_ conv: ConversationStore) async {
        guard injectedStore == nil else { return }
        await conv.start()
    }

    /// Idempotent: cached tail, image loader and saved draft are local reads only.
    @discardableResult
    private func prepareConversationIfNeeded() -> ConversationStore {
        if let conversationStore { return conversationStore }
        if let injectedStore {
            let hostID = appModel.selectedHost?.hostID ?? appModel.connectedHostID ?? ""
            draftHostID = hostID
            if !didLoadDraft {
                if let saved = ComposerDraftStore.load(hostID: hostID, sessionKey: session.key) {
                    draft = saved
                }
                didLoadDraft = true
            }
            conversationStore = injectedStore
            imageLoader = ChatImageLoader(client: appModel.client, hostID: hostID, sessionKey: session.key)
            return injectedStore
        }
        let hostID = appModel.selectedHost?.hostID
            ?? appModel.connectedHostID
            ?? ""
        draftHostID = hostID
        if !didLoadDraft {
            if let saved = ComposerDraftStore.load(hostID: hostID, sessionKey: session.key) {
                draft = saved
            }
            didLoadDraft = true
        }
        let client = appModel.client
        let conv = ConversationStore(
            sessionKey: session.key,
            client: client,
            live: session.live,
            attention: session.attention,
            hostID: hostID
        )
        if let metadataStore {
            conv.onSessionMetadata = { summary, revision in
                metadataStore.applySessionEvent(summary, revision: revision)
            }
        }
        conversationStore = conv
        imageLoader = ChatImageLoader(client: client, hostID: hostID, sessionKey: session.key)
        return conv
    }

    private var canShowAgentTerminal: Bool {
        #if os(iOS)
        ProductFeatures.terminalPaneEnabled && appModel.client?.hostCapabilities.terminalStream == true
        #else
        false
        #endif
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            ZStack {
                conversationContent
                    .opacity(pane == .chat || !canShowAgentTerminal ? 1 : 0)
                    .allowsHitTesting(pane == .chat || !canShowAgentTerminal)
                    .accessibilityHidden(pane != .chat && canShowAgentTerminal)
                #if os(iOS)
                if visitedTerminal && canShowAgentTerminal {
                    AgentTerminalPane(
                        session: session,
                        isPresented: pane == .terminal && !showProjectTerminal && !showUserPrompts
                    )
                }
                #endif
            }
            .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var conversationContent: some View {
        if let store = conversationStore {
            ChatView(
                store: store,
                runtimeID: session.runtime,
                sessionMarker: SessionPresentation.activityMarker(for: session),
                isConnected: isHostReady,
                isSending: isSending || isActionBusy,
                scrollToLatestRequest: scrollToLatestRequest,
                loadEarlierPullProgress: $loadEarlierPullProgress,
                scrollToMessageID: $scrollToMessageID,
                blockedQuestionRequestID: blockedQuestionRequestID,
                onQuestionSubmit: submitQuestion,
                onRetryMessage: retryFailedMessage
            )
            .environment(\.chatImageLoader, imageLoader)
            .environment(\.conversationScrollReadAction, acknowledgeScrollRead)
        } else {
            ProgressView()
        }
    }

    private var sessionHeaderLabel: some View {
        VStack(spacing: 2 * interfaceScale) {
            Text(SessionPresentation.displayTitle(for: session))
                .interfaceFont(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            // Running / waiting live only in the activity cue above the composer.
            HStack(spacing: Space.xs * interfaceScale) {
                if isRestarting {
                    ProgressView().interfaceControlSize(.mini)
                    Text("session.actions.restarting")
                        .interfaceFont(.caption2)
                        .foregroundStyle(.secondary)
                } else if ProductFeatures.terminalPaneEnabled, pane == .terminal {
                    Circle()
                        .fill(Palette.runtime(session.runtime))
                        .interfaceFrame(width: 6, height: 6)
                    Text("session.detail.terminal")
                        .interfaceFont(.caption2)
                        .foregroundStyle(.secondary)
                } else if let runtimeLabel = runtimeSubtitle {
                    Circle()
                        .fill(Palette.runtime(session.runtime))
                        .interfaceFrame(width: 6, height: 6)
                    Text(runtimeLabel)
                        .interfaceFont(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .interfaceFont(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("session.detail.user_prompts")
                        .interfaceFont(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .interfaceFont(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .interfaceFrame(minHeight: TouchTarget.minimum)
        .contentShape(Rectangle())
    }

    private var runtimeSubtitle: String? {
        let name = Palette.runtimeDisplayName(session.runtime)
        return name.isEmpty ? nil : name
    }

    /// Clear all client projections synchronously; the host confirms asynchronously.
    /// Keeping this on the detail also covers injected Mac pane stores.
    private func acknowledgeScrollRead() {
        guard let conversationStore,
              metadataStore?.markReadLocally(key: sessionKey) == true else { return }
        Task { await conversationStore.markRead() }
    }

    private var userPrompts: [RichMessage] {
        guard let store = conversationStore else { return [] }
        return store.userPrompts
    }

    private var composerStack: some View {
        VStack(spacing: 0) {
            if let composerError {
                HStack(spacing: Space.sm * interfaceScale) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                    Text(composerError)
                        .interfaceFont(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if restartFailed {
                        Button("session.actions.restart.retry", action: startRestart)
                            .interfaceFont(.footnote.weight(.medium))
                            .disabled(!isHostReady || isSending || isActionBusy)
                    }
                    Button {
                        clearComposerError()
                    } label: {
                        Image(systemName: "xmark")
                            .interfaceFont(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .interfaceFrame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(Text("action.dismiss"))
                }
                .interfacePadding(.leading, Space.base)
                .interfacePadding(.trailing, Space.xs)
                .interfacePadding(.vertical, Space.xs)
                .background(Palette.danger.opacity(0.12))
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            ComposerBar(
                text: $draft,
                attachments: $draftAttachments,
                isBusy: isSending || isActionBusy,
                autoFocus: autoFocusComposer,
                focusRequest: composerFocusRequest,
                onFocusChange: composerFocusChanged,
                history: userPrompts.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) },
                onStop: stopAction,
                isStopping: isInterrupting,
                onSend: submitDraft
            )
        }
    }

    private func composerFocusChanged(_ focused: Bool) {
        #if os(iOS)
        // The keyboard coming up always returns the reader to the latest
        // messages, even from history (owner requirement 2026-10-13).
        if focused { scrollToLatestRequest += 1 }
        #endif
        onComposerFocusChange?(focused)
    }

    private var isHostReady: Bool {
        guard let host = appModel.selectedHost else { return false }
        return appModel.isConnected(to: host) && appModel.client?.state == .ready
    }

    /// 右上复制/接力菜单的数据与动作（状态机与文案见 SessionActionsMenu）。
    private func loadRuntimes() async {
        guard let client = appModel.client else { return }
        guard let data = try? await client.call(WireProtocol.mRuntimesList) as? [String: Any],
              let items = data["runtimes"] as? [[String: Any]]
        else { return }
        // 逐条解码以保留 `available`：缺字段按可用，false 整行隐藏（不断言）；仅保留活跃运行时。
        runtimes = items.compactMap { try? RemoteJSONDecoder.decode(RuntimeEntry.self, from: $0) }.filter(\.isActive)
    }

#if DEBUG
    /// One-shot acceptance on an owned disposable conversation, using the same
    /// handlers as the composer, failed-message action and native menu.
    private func inspectDeliveryIfRequested(_ conv: ConversationStore) async {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectDelivery"),
              environment["CORRAL_INSPECTION_SESSION_KEY"] == sessionKey,
              session.cwd.contains("corral-phone-acceptance"),
              InspectionLaunchOptions.claimDeliveryInspection() else { return }
        // Cached conversation startup can finish before connection startup.
        // Wait for the same readiness gate a real foreground tap uses.
        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            if isHostReady { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let action = environment["CORRAL_INSPECTION_ACTION"] ?? "send"
        let before = conv.visibleMessages.count
        if action == "restart" {
            startRestart()
        } else if action == "retry", let failed = conv.messages.last(where: {
            $0.delivery == .failed || $0.delivery == .needsReview
        }) {
            retryFailedMessage(failed)
        } else if (action == "send" || action == "rejectRetry"), let text = environment["CORRAL_INSPECTION_TEXT"], !text.isEmpty {
            draft = text
            submitDraft(text, [])
        } else if action == "interrupt" {
            await inspectInterrupt(text: environment["CORRAL_INSPECTION_TEXT"], environment: environment)
        } else { return }
        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            if !isSending && !isActionBusy && !isInterrupting { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if action == "rejectRetry", let failed = conv.messages.last(where: { $0.delivery == .failed }) {
            // Leave the real failure visible for physical capture before retry.
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            retryFailedMessage(failed)
            for _ in 0..<100 {
                if !isSending { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let messages: [[String: Any]] = conv.messages.map { message in
            ["seq": message.seq, "text": message.text ?? "",
             "delivery": String(describing: message.delivery),
             "cause": message.failureDetail ?? "", "command_id": message.commandID ?? ""]
        }
        let receipt: [String: Any] = [
            "key": sessionKey, "action": action, "before_count": before,
            "messages": messages, "composer_error": composerError ?? "",
            "draft": draft, "busy": isSending || isActionBusy,
            "restart_failed": restartFailed,
            "restart_supported": appModel.client?.hostCapabilities.sessionRestart == true,
            "interrupt_supported": appModel.client?.hostCapabilities.sessionInterrupt == true,
            "running_after": isAssistantRunning
        ]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: .prettyPrinted) {
            try? data.write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("corral-delivery-inspection.json"), options: .atomic)
        }
    }
#endif

    private var isAssistantRunning: Bool {
        guard let store = conversationStore else { return false }
        let marker = SessionPresentation.activityMarker(for: session)
        return ChatActivityState.hasRunningTurn(
            state: ChatActivityState.resolve(store: store, connected: isHostReady, marker: marker),
            attention: store.displayAttention,
            hasRunningTool: store.hasRunningTool,
            marker: marker
        )
    }

    /// Stop shows while the turn runs, and stays (quiet) until an interrupt
    /// already sent has ended it.
    private var canInterrupt: Bool {
        (isAssistantRunning || isInterrupting)
            && isHostReady
            && appModel.client?.hostCapabilities.sessionInterrupt == true
    }

    private var stopAction: (() -> Void)? {
        guard canInterrupt else { return nil }
        return { interruptTurn() }
    }

    private func interruptTurn() {
        guard !isInterrupting, canInterrupt, let store = conversationStore else { return }
        // Acquired before the task: a second tap cannot send a second interrupt key.
        isInterrupting = true
        clearComposerError()
        let operationID = hapticScope.beginOperation()
        HapticFeedback.shared.emit(.committed, operationID: operationID, scope: hapticScope)
        Task {
            do {
                try await store.interrupt()
            } catch {
                isInterrupting = false
                showComposerError(SessionActionsMenu.failureMessage(for: error), operationID: operationID)
                return
            }
            // The host reports the turn end through the activity marker.
            for _ in 0..<40 where isAssistantRunning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            isInterrupting = false
        }
    }

#if DEBUG
    /// Sends the long task, waits until the stop button shows, holds it for a
    /// capture (`CORRAL_INSPECTION_STOP_DELAY` seconds), then runs the
    /// production stop handler.
    private func inspectInterrupt(text: String?, environment: [String: String]) async {
        if let text, !text.isEmpty {
            draft = text
            submitDraft(text, [])
        }
        for _ in 0..<300 {
            guard !Task.isCancelled else { return }
            if canInterrupt && !isSending { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let hold = environment["CORRAL_INSPECTION_STOP_DELAY"].flatMap(Double.init) ?? 0
        try? await Task.sleep(for: .seconds(hold))
        guard !Task.isCancelled else { return }
        interruptTurn()
    }
#endif

    private func startRestart() {
        // Restart stays serialized with sends that are still waiting in line.
        guard !isSending, !isActionBusy, isHostReady,
              conversationStore?.queuedOutboundCount ?? 0 == 0,
              let client = appModel.client,
              client.hostCapabilities.sessionRestart else { return }
        // Acquire before scheduling the task; repeated taps cannot start a second request.
        isActionBusy = true
        isRestarting = true
        clearComposerError()
        let operationID = hapticScope.beginOperation()
        Task {
            defer {
                isActionBusy = false
                isRestarting = false
            }
            do {
                _ = try await client.call(WireProtocol.mSessionRestart, params: ["key": sessionKey])
                HapticFeedback.shared.emit(.success, operationID: operationID, scope: hapticScope)
            } catch {
                showComposerError(SessionActionsMenu.failureMessage(for: error), operationID: operationID)
                restartFailed = true
            }
        }
    }

    private func copySession() async {
        let operationID = hapticScope.beginOperation()
        guard let client = appModel.client else {
            showComposerError(String(localized: String.LocalizationValue("error.not_connected")))
            return
        }
        isActionBusy = true
        defer { isActionBusy = false }
        do {
            let payload = try await client.call(
                WireProtocol.mSessionCopy,
                params: SessionActionsMenu.copyParams(sourceKey: sessionKey)
            )
            let created = try SessionActionsMenu.decodeNewSession(from: payload)
            conversationStore?.seedFork(sessionKey: created.key)
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectFork") {
                let receipt: [String: Any] = [
                    "source": sessionKey, "destination": created.key,
                    "inherited_count": conversationStore?.visibleMessages.filter { $0.seq > 0 }.count ?? 0
                ]
                if let data = try? JSONSerialization.data(withJSONObject: receipt) {
                    try? data.write(to: FileManager.default.temporaryDirectory
                        .appendingPathComponent("corral-fork-inspection.json"), options: .atomic)
                }
            }
#endif
            HapticFeedback.shared.emit(.success, operationID: operationID, scope: hapticScope)
            onDidCreateSession?(created)
        } catch {
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
            showComposerError(SessionActionsMenu.failureMessage(for: error), feedback: nil)
        }
    }

    private func handoffSession(to target: RuntimeEntry) async {
        let operationID = hapticScope.beginOperation()
        guard let client = appModel.client else {
            showComposerError(String(localized: String.LocalizationValue("error.not_connected")))
            return
        }
        isActionBusy = true
        defer { isActionBusy = false }
        do {
            let payload = try await client.call(
                WireProtocol.mSessionHandoff,
                params: SessionActionsMenu.handoffParams(sourceKey: sessionKey, targetRuntimeID: target.id)
            )
            let created = try SessionActionsMenu.decodeNewSession(from: payload)
            HapticFeedback.shared.emit(.success, operationID: operationID, scope: hapticScope)
            onDidCreateSession?(created)
        } catch {
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
            showComposerError(SessionActionsMenu.failureMessage(for: error), feedback: nil)
        }
    }

    /// Outbound send logic lives in `ConversationSendCoordinator` (portable,
    /// reusable from future iPad/Mac layouts). The view keeps UI state and
    /// wiring: these wrappers only build the display bridge and run the plan.
    private let sendCoordinator = ConversationSendCoordinator()

    private func submitDraft(_ text: String, _ images: [DraftImageAttachment]) {
        sendComposerDraft(text: text, images: images)
    }

    private func submitText(_ text: String) {
        sendComposerDraft(text: text, images: [])
    }

    private func submitQuestion(_ requestID: String, answers: [NativeQuestionAnswer]) {
        // Answering clears the refused-send hint for this request; a failed
        // answer re-arms it on the next refused send.
        if blockedQuestionRequestID == requestID {
            blockedQuestionRequestID = nil
        }
        let store: (any ConversationSendStore)? = conversationStore
        let display = DetailSendDisplay(view: self, hapticScope: hapticScope, sentImages: [])
        guard let plan = sendCoordinator.beginQuestionSubmit(
            requestID: requestID,
            answers: answers,
            store: store,
            display: display,
            isBusy: isSending || isActionBusy,
            isHostReady: isHostReady
        ) else { return }
        Task {
            await sendCoordinator.runQuestionSubmit(plan, store: store, display: display)
        }
    }

    /// Stage-aware send: images first (already cleared from the composer), then optional text.
    private func sendComposerDraft(text: String, images: [DraftImageAttachment]) {
        let staged = images.map {
            StagedSendImage(id: $0.id, base64: $0.base64, commandID: $0.commandID)
        }
        let store: (any ConversationSendStore)? = conversationStore
        let display = DetailSendDisplay(view: self, hapticScope: hapticScope, sentImages: images)
        guard let plan = sendCoordinator.beginComposerSend(
            store: store,
            display: display,
            text: text,
            images: staged,
            isBusy: isSending || isActionBusy,
            isHostReady: isHostReady
        ) else { return }
        Task {
            await sendCoordinator.runComposerSend(plan, store: store, display: display)
        }
    }

    private func restoreAttachments(from images: [DraftImageAttachment]) {
        let restoringIDs = Set(images.map(\.id))
        draftAttachments = images + draftAttachments.filter { !restoringIDs.contains($0.id) }
    }

    /// Shared send path. `reuseCommandID` keeps the same durable id on needsReview retry.
    private func sendUserText(
        _ text: String,
        reuseCommandID: String?,
        reuseSeq: Int?,
        clearDraftOnStart: Bool
    ) {
        let store: (any ConversationSendStore)? = conversationStore
        let display = DetailSendDisplay(view: self, hapticScope: hapticScope, sentImages: [])
        guard let plan = sendCoordinator.beginTextSend(
            text,
            store: store,
            display: display,
            reuseCommandID: reuseCommandID,
            reuseSeq: reuseSeq,
            clearDraftOnStart: clearDraftOnStart,
            isBusy: isSending || isActionBusy,
            isHostReady: isHostReady
        ) else { return }
        Task {
            await sendCoordinator.runTextSend(plan, store: store, display: display)
        }
    }

    private func retryFailedMessage(_ message: RichMessage) {
        let store: (any ConversationSendStore)? = conversationStore
        let display = DetailSendDisplay(view: self, hapticScope: hapticScope, sentImages: [])
        guard let plan = sendCoordinator.beginRetrySend(
            message,
            store: store,
            display: display,
            isBusy: isSending || isActionBusy,
            isHostReady: isHostReady
        ) else { return }
        Task {
            await sendCoordinator.runTextSend(plan, store: store, display: display)
        }
    }

    /// Wiring between `ConversationSendCoordinator` and this view's `@State`.
    /// Forwards composer state, scroll requests, error banner, haptics and the
    /// busy flag; maps restored staged images back onto the `UIImage`
    /// previews of the batch just sent.
    private final class DetailSendDisplay: ConversationSendDisplay {
        var view: SessionDetailView
        let hapticScope: HapticScope
        let sentImages: [DraftImageAttachment]

        init(view: SessionDetailView, hapticScope: HapticScope, sentImages: [DraftImageAttachment]) {
            self.view = view
            self.hapticScope = hapticScope
            self.sentImages = sentImages
        }

        var composerDraft: String {
            get { view.draft }
            set { view.draft = newValue }
        }

        func setSending(_ sending: Bool) {
            view.isSending = sending
        }

        func scrollToLatest() {
            view.scrollToLatestRequest += 1
        }

        func clearPersistedDraft() {
            view.clearPersistedDraft()
        }

        func persistDraft(_ text: String) {
            view.persistDraft(text)
        }

        func showError(_ message: String, haptic: ConversationSendHaptic?, operationID: UUID?) {
            view.showComposerError(message, feedback: hapticEventOrNil(for: haptic), operationID: operationID)
        }

        func clearError() {
            view.clearComposerError()
        }

        func emitHaptic(_ haptic: ConversationSendHaptic, operationID: UUID?) {
            HapticFeedback.shared.emit(
                hapticEvent(for: haptic),
                operationID: operationID,
                scope: hapticScope
            )
        }

        func beginHapticOperation() -> UUID {
            hapticScope.beginOperation()
        }

        func restoreImages(_ images: [StagedSendImage]) {
            let previews = Dictionary(uniqueKeysWithValues: sentImages.map { ($0.id, $0.preview) })
            view.restoreAttachments(from: images.compactMap { staged in
                guard let preview = previews[staged.id] else { return nil }
                var attachment = DraftImageAttachment(id: staged.id, base64: staged.base64, preview: preview)
                attachment.commandID = staged.commandID
                return attachment
            })
        }

        func showQuestionPending() {
            // The host refused chat input while its picker owns the keyboard:
            // glide to the open question card and show its quiet hint
            // instead of staging a bubble the host would refuse.
            view.blockedQuestionRequestID = view.conversationStore?.prompts.first?.requestID
            view.scrollToMessageID = "prompts"
        }

        private func hapticEventOrNil(for haptic: ConversationSendHaptic?) -> HapticEvent? {
            guard let haptic else { return nil }
            return hapticEvent(for: haptic)
        }

        private func hapticEvent(for haptic: ConversationSendHaptic) -> HapticEvent {
            switch haptic {
            case .committed: return .committed
            case .success: return .success
            case .error: return .error
            case .warning: return .warning
            }
        }
    }

    private func persistDraft(_ text: String) {
        guard didLoadDraft, !draftHostID.isEmpty else { return }
        ComposerDraftStore.save(hostID: draftHostID, sessionKey: session.key, text: text)
    }

    private func clearPersistedDraft() {
        guard !draftHostID.isEmpty else { return }
        ComposerDraftStore.remove(hostID: draftHostID, sessionKey: session.key)
    }

    private func showComposerError(_ message: String, feedback: HapticEvent? = .error, operationID: UUID? = nil) {
        if let feedback {
            HapticFeedback.shared.emit(feedback, operationID: operationID, scope: hapticScope)
        }
        restartFailed = false
        setComposerError(message)
    }

    private func clearComposerError() {
        restartFailed = false
        setComposerError(nil)
    }

    private func setComposerError(_ message: String?) {
        if reduceMotion {
            composerError = message
        } else {
            withAnimation(.easeInOut(duration: Motion.stateDuration)) {
                composerError = message
            }
        }
    }
}
