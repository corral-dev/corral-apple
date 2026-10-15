import Foundation
import Observation

/// 会话对话状态：消息列表、提问选项与错误可见状态。
///
/// 实时底部状态条改由 `TerminalStore` 提供——同一连接上重复 `screen.watch`
/// 会被服务端当成已订阅而返回空首帧，并在 `unwatch` 时误伤仍在看画面的一方。
@MainActor
@Observable
final class ConversationStore {
    private(set) var messages: [RichMessage] = [] {
        didSet {
            refreshTimeline()
        }
    }
    private var forkMessages: [RichMessage]? {
        didSet { refreshTimeline() }
    }
    /// Source history stays visible until the destination supplies its own usable tail.
    /// Destination local sends remain visible during that interval.
    var visibleMessages: [RichMessage] {
        guard let forkMessages else { return messages }
        return forkMessages + messages.filter(\.isLocal)
    }

    private func refreshTimeline() {
        userPromptsCacheSeqs = nil
        let next = ConversationMessagePolicy.timelineItems(
            from: visibleMessages, preserving: timelineItems
        )
        // Switching panes re-evaluates bodies without new data; assigning an
        // equal array still notifies Observation and rebuilds every row.
        let timelineChanged = next != timelineItems
        if timelineChanged {
            timelineItems = next
        }
        #if DEBUG
        if timelineChanged {
            ConversationStore.timelineRebuilds &+= 1
        } else {
            ConversationStore.timelineSkips &+= 1
        }
        #endif
        refreshRunningToolFlag()
    }

    /// Whether any message carries a running non-question tool. ChatView reads
    /// this per body evaluation; scanning all tools there repeats O(messages)
    /// work on every layout pass, so keep it beside the timeline projection.
    private(set) var hasRunningTool = false

    private func refreshRunningToolFlag() {
        let next = messages.contains {
            ($0.tools ?? []).contains { $0.status == "running" && $0.kind != "question" }
        }
        if next != hasRunningTool {
            hasRunningTool = next
        }
    }
    private(set) var prompts: [SessionPrompt] = []
    private(set) var questionSubmissionState: NativeQuestionSubmissionState?
    private(set) var questionFailureIsUncertain = false
    /// Host `session.prompts` answered once: its native request identity wins over the
    /// rough message-derived fallback, so incoming messages never reset question drafts.
    private var hostPromptsLoaded = false
    private var retiredQuestionRequestIDs = Set<String>()
    private(set) var isLive = false
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var isLoadingHistory = false
    private(set) var hasMoreHistory = false
    private(set) var oldestSequence = 0
    private(set) var newestSequence = 0
    private(set) var attention: AttentionKind = .none

    /// Set the instant the user submits text (or the host hints the turn started);
    /// shows Working before the agent's transcript confirms it.
    private(set) var provisionalWorkingSince: Date?
    private var provisionalExpiryTask: Task<Void, Never>?
    /// Without confirmation the provisional cue disappears on its own.
    static let provisionalWorkingTimeout: Duration = .seconds(20)
    /// An idle signal this soon after submitting is the pre-send state still in flight.
    static let provisionalIdleGrace: TimeInterval = 2

    /// Attention to display: authoritative working/waiting, else a pending
    /// provisional Working, else the authoritative value.
    var displayAttention: AttentionKind {
        if attention == .working || attention == .waiting { return attention }
        return provisionalWorkingSince != nil ? .working : attention
    }

    /// Assistant is running (authoritative or provisional). The activity cue above
    /// the composer owns this, not the header or a conversation strip.
    var isAssistantWorking: Bool { displayAttention == .working }

    private let sessionKey: String
    private let hostID: String
    private weak var client: RemoteClient?
    /// The connection this store subscribes on (containers rebind on reconnect).
    var boundClient: RemoteClient? { client }
    /// Forwards host metadata (title) events into the shared session list store.
    var onSessionMetadata: ((SessionSummary, UInt64?) -> Void)?
    /// 本地气泡从 -1 递减，永不使用 0（merge 会与缺 seq 的解码默认值撞车）。
    private var nextLocalSeq = -1
    private var attentionRevision = 0
    private var eventTask: Task<Void, Never>?
    private var receiptPollTask: Task<Void, Never>?
    private var readyHandlerID: UUID?
    private var catchUpTask: Task<Void, Never>?
    private var catchUpRequested = false
    /// 将一批实时增量收敛为一次提示选项查询，避免每条消息都占用同一条远程连接。
    private var promptRefreshTask: Task<Void, Never>?
    /// 上次成功应用到的历史代次；重连时带给开发机，对不上则改取尾部。
    private var generation = 0
    private var lifecycleRevision = 0
    private var snapshotRevision = 0
    private var promptRequestRevision = 0
    private var hasStopped = false
    /// Tail of this conversation's outgoing order (owner requirement 2026-10-11): the
    /// client queues sends, so the host never sees a second input while one is confirming.
    private var outboundTail: Task<Void, Never>?
    /// Sends handed to the outgoing order that have not finished their request yet.
    private(set) var queuedOutboundCount = 0
    /// Bounds startup, reconnect and receipt settlement before a later send leaves.
    static let outboundSettleTimeout: Duration = .seconds(120)

#if DEBUG
    /// Tests suspend an actual detail request while events alter the retained window.
    var commandStatusRequestForTesting: ((String) async throws -> Any)?
    /// Tests observe the order in which outgoing text reaches the host.
    var inputRequestForTesting: (@MainActor ([String: Any]) async throws -> Any)?
    /// Tests move local bubbles back in time (e.g. restored from an old cache).
    func ageLocalMessagesForTesting(by seconds: Double) {
        for index in messages.indices where messages[index].isLocal {
            messages[index].timestamp = (messages[index].timestamp ?? 0) - seconds
        }
    }
    var toolDetailRequestForTesting: ((Int) async throws -> SessionToolDetailResponse)?
#endif

    private(set) var timelineItems: [ConversationTimelineItem] = []

    /// Host list of every human prompt in the session (`session.userPrompts`).
    /// History is paged, but Your prompts covers the whole session.
    private var sessionPrompts: [RichMessage] = [] {
        didSet { userPromptsCacheSeqs = nil }
    }
    private var sessionPromptsGeneration = 0
    private var sessionPromptsTask: Task<Void, Never>?

    /// Your prompts, oldest first: the host's full list merged with loaded
    /// messages (loaded text wins); only the loaded part on hosts without the list.
    /// Bodies read this several times per layout pass; the string-heavy filter
    /// runs only when its inputs actually change (seq-keyed fast path first).
    @ObservationIgnored private var userPromptsCacheSeqs: (loaded: [Int], session: [Int], usable: Bool)?
    @ObservationIgnored private var userPromptsCacheValue: [RichMessage] = []
    var userPrompts: [RichMessage] {
        let usable = forkMessages == nil
            && (sessionPromptsGeneration == 0 || generation == 0 || sessionPromptsGeneration == generation)
        let loaded = visibleMessages
        // Integer fast path: unchanged seqs reuse the filtered result without
        // re-trimming and re-scanning every message body.
        let loadedSeqs = loaded.map(\.seq)
        let sessionSeqs = usable ? sessionPrompts.map(\.seq) : []
        if let key = userPromptsCacheSeqs, key.loaded == loadedSeqs,
           key.session == sessionSeqs, key.usable == usable {
            #if DEBUG
            ConversationStore.promptsHits &+= 1
            #endif
            return userPromptsCacheValue
        }
        let value = ConversationMessagePolicy.userPrompts(
            loaded: loaded,
            session: usable ? sessionPrompts : []
        )
        userPromptsCacheSeqs = (loadedSeqs, sessionSeqs, usable)
        userPromptsCacheValue = value
        #if DEBUG
        ConversationStore.promptsRecomputes &+= 1
        #endif
        return value
    }

    #if DEBUG
    /// Warm-switch diagnostics: how often cached projections actually reuse
    /// their filtered results instead of re-scanning message bodies.
    static var timelineRebuilds = 0
    static var timelineSkips = 0
    static var promptsHits = 0
    static var promptsRecomputes = 0
    static func resetSwitchCounters() {
        timelineRebuilds = 0
        timelineSkips = 0
        promptsHits = 0
        promptsRecomputes = 0
    }
    #endif

    var supportsCommandReceipts: Bool {
        client?.supportsCommandReceipts == true
    }

    var supportsToolDetail: Bool {
        client?.supportsToolDetail == true
    }

    init(
        sessionKey: String,
        client: RemoteClient?,
        live: Bool,
        attention: AttentionKind = .none,
        hostID: String = ""
    ) {
        self.sessionKey = sessionKey
        self.client = client
        self.isLive = live
        self.attention = attention
        self.hostID = hostID
        loadPersistedTail()
    }

    /// Paint cached tail immediately so reopen never flash-empty.
    func loadPersistedTail() {
        guard !hostID.isEmpty else { return }
        guard let snapshot = ConversationTailCache.load(hostID: hostID, sessionKey: sessionKey) else {
            return
        }
        messages = snapshot.messages
        forkMessages = snapshot.forkMessages
        oldestSequence = snapshot.oldestSequence
        newestSequence = snapshot.newestSequence
        hasMoreHistory = snapshot.hasMoreHistory
        generation = snapshot.generation
        restoreLocalSeqCursor()
        extractOptionsFromMessages()
    }

    /// Called after session.copy succeeds and before navigation opens the new detail.
    /// The source remains untouched and the destination starts with independent cursors.
    func seedFork(sessionKey destinationKey: String) {
        guard !hostID.isEmpty, !destinationKey.isEmpty, destinationKey != sessionKey else { return }
        let inherited = visibleMessages.filter { $0.seq > 0 }.suffix(
            ConversationHistoryBudget.maxOfficialMessagesPerSession
        ).map { message in
            var copy = message
            copy.commandID = nil
            copy.localAfterSeq = nil
            copy.failureDetail = nil
            copy.delivery = .sent
            copy.tools = copy.tools?.map { $0.strippingBodies() }
            return copy
        }
        guard !inherited.isEmpty else { return }
        ConversationTailCache.save(ConversationTailSnapshot(
            hostID: hostID, sessionKey: destinationKey, messages: [],
            oldestSequence: 0, newestSequence: 0, hasMoreHistory: false,
            generation: 0, savedAt: Date(), forkMessages: inherited
        ))
    }

    /// 立刻画出自己的气泡。相同正文的失败/发送中气泡复用原序号，避免两条一样的。
    @discardableResult
    func enqueueLocalUser(_ text: String, commandID: String? = nil, reusingSeq: Int? = nil) -> Int {
        if let reusingSeq, let index = messages.firstIndex(where: {
            $0.seq == reusingSeq && $0.isLocal && $0.delivery == .failed
        }) {
            if let previousID = messages[index].commandID, !hostID.isEmpty {
                PendingCommandStore.remove(hostID: hostID, commandID: previousID)
            }
            messages[index].commandID = commandID
            messages[index].delivery = .pending
            messages[index].failureDetail = nil
            return messages[index].seq
        }
        let trimmed = ConversationMessageMerge.normalizedText(text)
        if let index = messages.lastIndex(where: { message in
            guard message.isLocal, message.role.lowercased() == "user" else { return false }
            if let commandID, !commandID.isEmpty {
                return message.commandID == commandID
                    || (message.delivery == .failed
                        && ConversationMessageMerge.normalizedText(message.text) == trimmed)
            }
            return message.commandID == nil
                && (message.delivery == .pending || message.delivery == .failed)
                && ConversationMessageMerge.normalizedText(message.text) == trimmed
        }) {
            if let previousID = messages[index].commandID, previousID != commandID, !hostID.isEmpty {
                PendingCommandStore.remove(hostID: hostID, commandID: previousID)
            }
            messages[index].delivery = .pending
            messages[index].failureDetail = nil
            if let commandID {
                messages[index].commandID = commandID
            }
            return messages[index].seq
        }
        let seq = allocateLocalSeq()
        messages.append(
            RichMessage(
                seq: seq,
                role: "user",
                text: trimmed,
                delivery: .pending,
                timestamp: Date().timeIntervalSince1970,
                commandID: commandID,
                localAfterSeq: newestOfficialSeq
            )
        )
        return seq
    }

    func markLocalSent(text: String? = nil, seq: Int? = nil) {
        updateLocalDelivery(.sent, text: text, seq: seq)
    }

    func markLocalAccepted(text: String? = nil, seq: Int? = nil) {
        updateLocalDelivery(.accepted, text: text, seq: seq)
    }

    func markLocalFailed(text: String? = nil, seq: Int? = nil, failureDetail: String? = nil) {
        updateLocalDelivery(.failed, text: text, seq: seq, failureDetail: failureDetail)
    }

    func markLocalNeedsReview(text: String? = nil, seq: Int? = nil, failureDetail: String? = nil) {
        updateLocalDelivery(.needsReview, text: text, seq: seq, failureDetail: failureDetail)
    }

    func start() async {
        catchUpTask?.cancel()
        catchUpTask = nil
        catchUpRequested = false
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        hasStopped = false
#if DEBUG
        // Same-app physical acceptance: keep the real fork's first frame visible
        // without letting a fast host snapshot hide the pending-sync interval.
        if forkMessages != nil,
           ProcessInfo.processInfo.arguments.contains("-CorralInspectForkPending") {
            return
        }
#endif
        guard let client else {
            // Offline / no client: keep cached tail visible; surface a soft error only if empty.
            if visibleMessages.isEmpty {
                let message = String(localized: String.LocalizationValue("error.not_connected"))
                if loadError != message {
                    loadError = message
                }
            }
            return
        }
        let needsLoading = visibleMessages.isEmpty
        if isLoading != needsLoading {
            isLoading = needsLoading
        }
        if loadError != nil {
            loadError = nil
        }

        // 先挂订阅再发 watch，避免服务端首批推送落在订阅登记之前被丢掉。
        ensureEventSubscription(client)
        registerReadyHandler(client)
        await pullSnapshot(client)
        guard lifecycleRevision == revision, !hasStopped, !Task.isCancelled else { return }
        await reconcilePendingCommands(client)
        guard lifecycleRevision == revision, !hasStopped, !Task.isCancelled else { return }
        if isLoading {
            isLoading = false
        }
        persistTail()
    }

#if DEBUG
    /// Layout tests paint the empty-loading pane without a live client.
    func setLoadingForLayoutTest(_ loading: Bool) {
        isLoading = loading
        if loading {
            loadError = nil
        }
    }
#endif

    func stop() async {
        hasStopped = true
        lifecycleRevision &+= 1
        isLoading = false
        isLoadingHistory = false
        persistTail()
        if let readyHandlerID {
            client?.removeReadyHandler(readyHandlerID)
            self.readyHandlerID = nil
        }
        receiptPollTask?.cancel()
        receiptPollTask = nil
        catchUpTask?.cancel()
        catchUpTask = nil
        catchUpRequested = false
        eventTask?.cancel()
        eventTask = nil
        promptRefreshTask?.cancel()
        promptRefreshTask = nil
        sessionPromptsTask?.cancel()
        sessionPromptsTask = nil
        provisionalExpiryTask?.cancel()
        provisionalExpiryTask = nil
        _ = try? await client?.call(WireProtocol.mSessionUnwatch, params: ["key": sessionKey])
    }

    /// Show Working now; the host's authoritative attention takes over when it arrives.
    func beginProvisionalWorking(now: Date = Date()) {
        provisionalWorkingSince = now
        provisionalExpiryTask?.cancel()
        provisionalExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.provisionalWorkingTimeout)
            guard !Task.isCancelled, let self, self.provisionalWorkingSince == now else { return }
            self.provisionalWorkingSince = nil
            self.provisionalExpiryTask = nil
        }
    }

    func cancelProvisionalWorking() {
        provisionalWorkingSince = nil
        provisionalExpiryTask?.cancel()
        provisionalExpiryTask = nil
    }

    /// Host-confirmed attention. Working/waiting take over from the provisional cue;
    /// an idle signal clears it only after the grace window (an earlier one predates the send).
    private func applyAuthoritativeAttention(_ value: AttentionKind, now: Date = Date()) {
        if value != attention {
            attention = value
        }
        guard let since = provisionalWorkingSince else { return }
        switch value {
        case .working, .waiting:
            cancelProvisionalWorking()
        case .none, .unread:
            if now.timeIntervalSince(since) >= Self.provisionalIdleGrace {
                cancelProvisionalWorking()
            }
        }
    }

    /// Runs `operation` after every earlier send in this conversation has left and its
    /// host outcome has settled, so input reaches the assistant in tap order.
    private func inOutboundOrder(
        excludingCommandID: String? = nil,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let previous = outboundTail
        queuedOutboundCount += 1
        defer { queuedOutboundCount -= 1 }
        let turn = Task { @MainActor [weak self] in
            await previous?.value
            await self?.waitForEarlierDeliveries(excludingCommandID: excludingCommandID)
            try await operation()
        }
        outboundTail = Task { _ = try? await turn.value }
        try await turn.value
    }

    /// An earlier message is still being confirmed while it is `accepted` with a
    /// command identity inside the settle window. Identity-less echoes and stale
    /// bubbles (e.g. restored from the reopen cache) are never confirmed by
    /// receipt polling, so they must not hold back new sends.
    private func waitForEarlierDeliveries(excludingCommandID: String?) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.outboundSettleTimeout)
        while !hasStopped, clock.now < deadline,
              hasConfirmingSend(now: Date(), excludingCommandID: excludingCommandID) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func hasConfirmingSend(now: Date, excludingCommandID: String?) -> Bool {
        let window = Double(Self.outboundSettleTimeout.components.seconds)
        return messages.contains { message in
            guard message.isLocal, message.delivery == .accepted, message.commandID != nil,
                  message.commandID != excludingCommandID,
                  let sentAt = message.timestamp else { return false }
            return now.timeIntervalSince1970 - sentAt < window
        }
    }

    /// Send text once, after earlier sends in this conversation. When receipts are
    /// available, callers must already have persisted a pending bubble + `command_id`
    /// and cleared the composer.
    func sendText(_ text: String, submit: Bool = true, commandID: String? = nil) async throws {
        try await inOutboundOrder(excludingCommandID: commandID) { [weak self] in
            try await self?.deliverText(text, submit: submit, commandID: commandID)
        }
    }

    private func deliverText(_ text: String, submit: Bool, commandID: String?) async throws {
        guard let client else {
            throw RemoteClient.ConnectionError.notConnected
        }
#if DEBUG && os(iOS)
        let targetKey = InspectionLaunchOptions.claimRejectedSend(sessionKey: sessionKey, text: text)
            ? "codex:corral-phone-acceptance-missing-target" : sessionKey
#else
        let targetKey = sessionKey
#endif
        let params: [String: Any] = [
            "key": targetKey,
            "text": text,
            "submit": submit,
            "command_id": commandID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
            "lease_sec": 90,
        ]
        let startsTurn = submit && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if startsTurn {
            beginProvisionalWorking()
        }
        let payload: Any
        do {
            payload = try await requestInputText(params, client: client)
        } catch {
            if startsTurn { cancelProvisionalWorking() }
            throw error
        }
        if let commandID = params["command_id"] as? String,
           let receipt = CommandStatusResponse.receipt(from: payload),
           let status = receipt.status {
            applyCommandStatus(commandID: commandID, status: status, failureDetail: receipt.detail)
            switch PendingCommandStore.delivery(fromHostStatus: status) {
            case .failed:
                throw CommandDeliveryError.rejected(receipt.detail ?? String(localized: "chat.delivery.no_reason"))
            case .needsReview:
                throw CommandDeliveryError.unconfirmed(receipt.detail ?? String(localized: "chat.delivery.unknown"))
            default: break
            }
        }
    }

    private func requestInputText(_ params: [String: Any], client: RemoteClient) async throws -> Any {
        let hostID = client.reconnectHost?.hostID
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        var receiptCapable = client.supportsCommandReceipts
        for attempt in 0..<3 {
            do {
#if DEBUG
                if let hook = inputRequestForTesting { return try await hook(params) }
#endif
                guard ContinuousClock.now < deadline else { throw RemoteClient.ConnectionError.notConnected }
                try await client.waitForInputReadiness(timeout: ContinuousClock.now.duration(to: deadline))
                guard client.reconnectHost?.hostID == hostID else { throw CancellationError() }
                receiptCapable = receiptCapable || client.supportsCommandReceipts
                return try await client.call(WireProtocol.mInputText, params: params)
            } catch {
                // Only a durable receipt permits retry after a potentially sent
                // frame. Reuse the same command identity; never retry a rejection.
                guard receiptCapable, attempt < 2, client.allowReconnect,
                      client.reconnectHost?.hostID == hostID,
                      Self.isInputTransportFailure(error) else { throw error }
                try await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            }
        }
        throw RemoteClient.ConnectionError.notConnected
    }

    private static func isInputTransportFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? RemoteClient.ConnectionError else { return false }
        switch error {
        case .notConnected, .timeout, .sendFailed: return true
        default: return false
        }
    }

    func sendKeys(_ keys: [String], commandID: String? = nil) async throws {
        guard let client else {
            throw RemoteClient.ConnectionError.notConnected
        }
        let params: [String: Any] = [
            "key": sessionKey,
            "keys": keys,
            "command_id": commandID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
        ]
        _ = try await client.call(WireProtocol.mInputKeys, params: params)
    }

    /// Stops the running turn. Not queued behind sends, never retried: a second
    /// interrupt key on an idle assistant opens its history navigation.
    func interrupt() async throws {
        guard let client else {
            throw RemoteClient.ConnectionError.notConnected
        }
        _ = try await client.call(WireProtocol.mSessionInterrupt, params: ["key": sessionKey])
    }

    func sendImage(base64: String, commandID: String? = nil) async throws {
        try await inOutboundOrder(excludingCommandID: commandID) { [weak self] in
            try await self?.deliverImage(base64: base64, commandID: commandID)
        }
    }

    private func deliverImage(base64: String, commandID: String?) async throws {
        guard let client else {
            throw RemoteClient.ConnectionError.notConnected
        }
        let params: [String: Any] = [
            "key": sessionKey,
            "data": base64,
            "command_id": commandID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
        ]
        let payload = try await client.call(WireProtocol.mInputImage, params: params)
        if let commandID = params["command_id"] as? String,
           let receipt = CommandStatusResponse.receipt(from: payload),
           let status = receipt.status {
            applyCommandStatus(commandID: commandID, status: status, failureDetail: receipt.detail)
            switch PendingCommandStore.delivery(fromHostStatus: status) {
            case .failed:
                throw CommandDeliveryError.rejected(receipt.detail ?? String(localized: "chat.delivery.no_reason"))
            case .needsReview:
                throw CommandDeliveryError.unconfirmed(receipt.detail ?? String(localized: "chat.delivery.unknown"))
            default: break
            }
        } else if !supportsCommandReceipts, let commandID = params["command_id"] as? String {
            // Legacy hosts never return a receipt: a successful RPC is delivery.
            // Settle here so the bubble does not stay pending forever.
            applyCommandStatus(commandID: commandID, status: "delivered", failureDetail: nil)
        }
    }

    func markRead() async {
        _ = try? await client?.call(WireProtocol.mSessionMarkRead, params: ["key": sessionKey])
    }

    func retry() async {
        await start()
    }

    /// Persist a pending outgoing command before the network call (receipts path).
    func recordPendingCommand(commandID: String, text: String, localSeq: Int) {
        guard !hostID.isEmpty, !commandID.isEmpty else { return }
        PendingCommandStore.upsert(
            PendingCommandRecord(
                commandID: commandID,
                hostID: hostID,
                sessionKey: sessionKey,
                text: text,
                localSeq: localSeq,
                delivery: .pending,
                createdAt: Date()
            )
        )
    }

    func applyCommandStatus(commandID: String, status: String, failureDetail: String? = nil) {
        let delivery = PendingCommandStore.delivery(fromHostStatus: status)
        updateLocalDelivery(delivery, commandID: commandID, failureDetail: failureDetail)
        if delivery == .failed || delivery == .needsReview {
            cancelProvisionalWorking()
        }
        if !hostID.isEmpty {
            PendingCommandStore.updateDelivery(
                hostID: hostID, commandID: commandID, delivery: delivery,
                failureDetail: failureDetail
            )
        }
        persistTail()
        if delivery == .accepted || delivery == .pending || delivery == .needsReview { ensureReceiptPolling() }
    }

    private func ensureReceiptPolling() {
        guard receiptPollTask == nil, !hasStopped, let client else { return }
        receiptPollTask = Task { [weak self] in
            defer { self?.receiptPollTask = nil }
            let deadline = Date().addingTimeInterval(95)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.hasStopped, !Task.isCancelled else { return }
                await self.reconcilePendingCommands(client)
                let pending = PendingCommandStore.unresolved(hostID: self.hostID, sessionKey: self.sessionKey)
                guard pending.contains(where: { $0.delivery == .accepted || $0.delivery == .pending }) else { return }
            }
            guard let self, !self.hasStopped, !Task.isCancelled else { return }
            for record in PendingCommandStore.unresolved(hostID: self.hostID, sessionKey: self.sessionKey)
            where record.delivery == .accepted || record.delivery == .pending {
                self.applyCommandStatus(
                    commandID: record.commandID, status: "unknown",
                    failureDetail: String(localized: "chat.delivery.unknown")
                )
            }
        }
    }

    private func ensureEventSubscription(_ client: RemoteClient) {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.subscribe(channel: WireProtocol.sessionChannel(sessionKey: sessionKey)) {
                if Task.isCancelled { break }
                await self.handle(event)
            }
        }
    }

    private func registerReadyHandler(_ client: RemoteClient) {
        guard readyHandlerID == nil else { return }
        readyHandlerID = client.addReadyHandler { [weak self] in
            self?.requestCatchUp()
        }
    }

    private func requestCatchUp() {
        guard !hasStopped, client != nil else { return }
        catchUpRequested = true
        guard catchUpTask == nil else { return }
        let revision = lifecycleRevision
        catchUpTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleRevision == revision { self.catchUpTask = nil }
            }
            while self.catchUpRequested, !self.hasStopped,
                  self.lifecycleRevision == revision, !Task.isCancelled {
                self.catchUpRequested = false
                await self.repullAfterReconnect()
            }
        }
    }

    private func repullAfterReconnect() async {
        guard let client, !hasStopped else { return }
        let revision = lifecycleRevision
        // 本地 AsyncStream 订阅在重连时保留；只需重新向服务端登记 watch。
        await pullSnapshot(client, resumeCursor: true)
        guard lifecycleRevision == revision, !hasStopped, !Task.isCancelled else { return }
        await reconcilePendingCommands(client)
        guard lifecycleRevision == revision, !hasStopped, !Task.isCancelled else { return }
        persistTail()
    }

    private func reconcilePendingCommands(_ client: RemoteClient) async {
        guard client.supportsCommandReceipts, !hostID.isEmpty, !hasStopped else { return }
        let lifecycle = lifecycleRevision
        let pending = PendingCommandStore.unresolved(hostID: hostID, sessionKey: sessionKey)
        for record in pending {
            guard !hasStopped, lifecycle == lifecycleRevision, !Task.isCancelled else { return }
            do {
                let payload: Any
#if DEBUG
                if let commandStatusRequestForTesting {
                    payload = try await commandStatusRequestForTesting(record.commandID)
                } else {
                    payload = try await client.call(WireProtocol.mCommandStatus, params: ["command_id": record.commandID, "key": sessionKey])
                }
#else
                payload = try await client.call(WireProtocol.mCommandStatus, params: ["command_id": record.commandID, "key": sessionKey])
#endif
                guard !hasStopped, lifecycle == lifecycleRevision, !Task.isCancelled else { return }
                if let receipt = CommandStatusResponse.receipt(from: payload),
                   let status = receipt.status {
                    applyCommandStatus(
                        commandID: record.commandID, status: status,
                        failureDetail: receipt.detail
                    )
                }
            } catch {
                guard !hasStopped, lifecycle == lifecycleRevision, !Task.isCancelled else { return }
                // Keep local pending/review state; do not invent a resend.
                continue
            }
        }
    }

    private func pullSnapshot(_ client: RemoteClient, resumeCursor: Bool = false) async {
        guard !hasStopped else { return }
        snapshotRevision &+= 1
        let requestRevision = snapshotRevision
        let lifecycle = lifecycleRevision
        do {
            var params: [String: Any] = ["key": sessionKey]
            if resumeCursor, forkMessages == nil {
                params["after_seq"] = newestSequence
                params["generation"] = generation
            }
            let stateRevision = attentionRevision
            let watch = try await client.call(
                WireProtocol.mSessionWatch,
                params: params,
                as: SessionMessagesResponse.self
            )
            try Task.checkCancellation()
            guard !hasStopped, lifecycle == lifecycleRevision,
                  requestRevision == snapshotRevision else { return }
            if attentionRevision == stateRevision {
                if let current = watch.attention { applyAuthoritativeAttention(current) }
                if let current = watch.live, current != isLive { isLive = current }
            }
            applySnapshot(watch)
            if loadError != nil {
                loadError = nil
            }
            refreshSessionPrompts(client)
            await loadPrompts()
            guard !hasStopped, lifecycle == lifecycleRevision,
                  requestRevision == snapshotRevision, !Task.isCancelled else { return }
            persistTail()
        } catch {
            guard !hasStopped, lifecycle == lifecycleRevision,
                  requestRevision == snapshotRevision, !Task.isCancelled else { return }
            // 已有缓存时保留画面，只露出错误提示。
            if visibleMessages.isEmpty {
                let message = error.localizedDescription
                if loadError != message {
                    loadError = message
                }
            }
        }
    }

    func applySnapshot(_ watch: SessionMessagesResponse) {
        let applied = ConversationWatchApply.apply(
            local: messages,
            localOldest: oldestSequence,
            localNewest: newestSequence,
            localHasMore: hasMoreHistory,
            localGeneration: generation,
            incoming: watch.messages,
            incomingOldest: watch.oldestSeq,
            incomingNewest: watch.newestSeq,
            incomingHasMore: watch.hasMore,
            incomingGeneration: watch.generation,
            resume: watch.resume
        )
        // Warm re-watch with identical tails must not invalidate rows: equal
        // assignments still notify Observation and rebuild the timeline.
        if applied.messages != messages {
            messages = applied.messages
        }
        if applied.oldestSequence != oldestSequence {
            oldestSequence = applied.oldestSequence
        }
        if applied.newestSequence != newestSequence {
            newestSequence = applied.newestSequence
        }
        if applied.hasMoreHistory != hasMoreHistory {
            hasMoreHistory = applied.hasMoreHistory
        }
        if applied.generation != generation {
            generation = applied.generation
        }
        if forkMessages != nil, watch.messages.contains(where: { $0.seq > 0 }) {
            forkMessages = nil
        }
    }

    func loadEarlier() async {
        guard hasMoreHistory, !isLoadingHistory, oldestSequence > 0 else { return }
        guard let client else {
            // Earlier pages already on disk stay visible; only unread older history needs the host.
            if loadError == nil {
                loadError = String(localized: String.LocalizationValue("error.not_connected"))
            }
            return
        }
        guard !hasStopped else { return }
        let lifecycle = lifecycleRevision
        let historyGeneration = generation
        isLoadingHistory = true
        defer {
            if lifecycle == lifecycleRevision { isLoadingHistory = false }
        }
        do {
            let page = try await client.call(
                WireProtocol.mSessionMessages,
                params: [
                    "key": sessionKey,
                    "limit": WireProtocol.messagePageLimit,
                    "before_seq": oldestSequence,
                ],
                as: SessionMessagesResponse.self
            )
            try Task.checkCancellation()
            guard !hasStopped, lifecycle == lifecycleRevision,
                  generation == historyGeneration,
                  page.generation == 0 || historyGeneration == 0 || page.generation == historyGeneration
            else { return }
            merge(page.messages)
            if page.oldestSeq > 0 {
                if page.oldestSeq != oldestSequence {
                    oldestSequence = page.oldestSeq
                }
            } else {
                let floored = oldestOfficialSeq
                if floored != oldestSequence {
                    oldestSequence = floored
                }
            }
            if page.hasMore != hasMoreHistory {
                hasMoreHistory = page.hasMore
            }
            if loadError != nil {
                loadError = nil
            }
            persistTail()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, !hasStopped, lifecycle == lifecycleRevision else { return }
            let message = error.localizedDescription
            if loadError != message {
                loadError = message
            }
        }
    }

    /// Pages earlier until `seq` is loaded (a Your prompts jump past the window).
    /// Returns whether it is loaded; stops when history ends or a page fails.
    @discardableResult
    func loadEarlier(through seq: Int) async -> Bool {
        while !messages.contains(where: { $0.seq == seq }) {
            guard hasMoreHistory, oldestSequence > seq, !hasStopped else { break }
            let before = oldestSequence
            await loadEarlier()
            if oldestSequence >= before { break }
        }
        return messages.contains { $0.seq == seq }
    }

    private func refreshSessionPrompts(_ client: RemoteClient) {
        guard client.supportsUserPrompts, forkMessages == nil else { return }
        sessionPromptsTask?.cancel()
        let lifecycle = lifecycleRevision
        sessionPromptsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.call(
                    WireProtocol.mSessionUserPrompts,
                    params: ["key": self.sessionKey],
                    as: SessionUserPromptsResponse.self
                )
                try Task.checkCancellation()
                guard !self.hasStopped, lifecycle == self.lifecycleRevision else { return }
                if response.prompts != self.sessionPrompts {
                    self.sessionPrompts = response.prompts
                }
                if response.generation != self.sessionPromptsGeneration {
                    self.sessionPromptsGeneration = response.generation
                }
            } catch {
                // Keep the previous list; Your prompts falls back to loaded messages.
                return
            }
        }
    }

    private func loadPrompts() async {
        guard let client, !hasStopped else { return }
        promptRequestRevision &+= 1
        let requestRevision = promptRequestRevision
        let lifecycle = lifecycleRevision
        do {
            let response = try await client.call(
                WireProtocol.mSessionPrompts,
                params: ["key": sessionKey],
                as: SessionPromptsResponse.self
            )
            try Task.checkCancellation()
            guard !hasStopped, lifecycle == lifecycleRevision,
                  requestRevision == promptRequestRevision else { return }
            hostPromptsLoaded = true
            applyPrompts(response.prompts)
        } catch {
            guard !hasStopped, lifecycle == lifecycleRevision,
                  requestRevision == promptRequestRevision, !Task.isCancelled else { return }
            extractOptionsFromMessages()
        }
    }

    func submitQuestion(requestID: String, answers: [NativeQuestionAnswer]) async {
        guard !hasStopped else { return }
        questionFailureIsUncertain = false
        let lifecycle = lifecycleRevision
        guard prompts.contains(where: { $0.requestID == requestID }) else {
            questionSubmissionState = .init(requestID: requestID, status: .stale(nil))
            await loadPrompts()
            return
        }
        guard let client else {
            questionSubmissionState = .init(
                requestID: requestID,
                status: .failed(String(localized: String.LocalizationValue("error.not_connected")))
            )
            return
        }

        questionSubmissionState = .init(requestID: requestID, status: .submitting)
        do {
            let response = try await client.call(
                WireProtocol.mInputQuestion,
                params: [
                    "key": sessionKey,
                    "request_id": requestID,
                    "answers": answers.map { $0.wireValue() }
                ],
                as: NativeQuestionAnswerResult.self
            )
            try Task.checkCancellation()
            guard !hasStopped, lifecycle == lifecycleRevision, !Task.isCancelled,
                  prompts.contains(where: { $0.requestID == requestID }) else { return }
            switch response.status {
            case .delivered:
                retiredQuestionRequestIDs.insert(requestID)
                promptRequestRevision &+= 1
                applyPrompts(prompts.filter { $0.requestID != requestID })
                await loadPrompts()
            case .stale:
                questionSubmissionState = .init(requestID: requestID, status: .stale(response.detail))
                await loadPrompts()
            case .unavailable:
                questionSubmissionState = .init(requestID: requestID, status: .unavailable(response.detail))
                await loadPrompts()
            }
        } catch {
            guard !hasStopped, lifecycle == lifecycleRevision, !Task.isCancelled,
                  prompts.contains(where: { $0.requestID == requestID }) else { return }
            let detail = (error as? RemoteCallError)?.message ?? error.localizedDescription
            questionFailureIsUncertain = PendingCommandStore.hostStatusAfterSendFailure(error) != "rejected"
            questionSubmissionState = .init(requestID: requestID, status: .failed(detail))
        }
    }

    private func applyPrompts(_ newPrompts: [SessionPrompt]) {
        let pending = newPrompts.filter { !retiredQuestionRequestIDs.contains($0.requestID) }
        let nextRequestID = pending.first?.requestID
        if nextRequestID != questionSubmissionState?.requestID {
            questionSubmissionState = nil
        }
        let filtered = pending.filter { $0.requestID == nextRequestID }
        if filtered != prompts {
            prompts = filtered
        }
    }

    private func extractOptionsFromMessages() {
        guard !hostPromptsLoaded else { return }
        applyPrompts(ConversationPromptPolicy.pendingPrompts(from: messages))
    }

    func handle(_ event: RemoteEvent) async {
        guard !hasStopped else { return }
        if let eventSession = event.data["session"] as? String, eventSession != sessionKey {
            return
        }
        let kind = (event.data["kind"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if kind == "attention" {
            let wasWorking = isAssistantWorking
            applyAttention(from: event.data)
            if wasWorking, !isAssistantWorking { requestCatchUp() }
            return
        }
        if kind == "metadata" {
            applyMetadata(from: event.data)
            return
        }
        if kind == "echo" {
            applyEcho(from: event.data)
            persistTail()
            return
        }
        if kind == "history_reset" {
            if let snapshot = try? RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: event.data),
               snapshot.generation > generation {
                applySnapshot(snapshot)
                if let client { refreshSessionPrompts(client) }
            }
            return
        }
        if kind == "command" || kind == "command_status" || kind == "receipt" {
            if let commandID = (event.data["command_id"] as? String)
                ?? (event.data["commandID"] as? String),
               let receipt = CommandStatusResponse.receipt(from: event.data),
               let status = receipt.status ?? (event.data["status"] as? String) {
                applyCommandStatus(commandID: commandID, status: status, failureDetail: receipt.detail)
            }
            return
        }
        var incoming: [RichMessage] = []
        if let messageDict = event.data["message"] as? [String: Any],
           let message = try? RemoteJSONDecoder.decode(RichMessage.self, from: messageDict),
           message.seq > 0 {
            incoming.append(message)
        } else if let batch = event.data["messages"] as? [[String: Any]] {
            for item in batch {
                if let message = try? RemoteJSONDecoder.decode(RichMessage.self, from: item),
                   message.seq > 0 {
                    incoming.append(message)
                }
            }
        } else if let batchAny = event.data["messages"] as? [Any] {
            for item in batchAny {
                if let message = try? RemoteJSONDecoder.decode(RichMessage.self, from: item),
                   message.seq > 0 {
                    incoming.append(message)
                }
            }
        }
        guard !incoming.isEmpty else { return }
        if let fromSequence = event.data["from_seq"] as? Int,
           newestSequence > 0,
           fromSequence > newestSequence + 1 {
            if let client {
                await pullSnapshot(client)
            }
            return
        }
        merge(incoming)
        // Deltas use destination sequence numbers. Fetch its full current tail
        // before replacing source history, rather than merging unrelated seqs.
        if forkMessages != nil, let client {
            await pullSnapshot(client)
        }
        schedulePromptRefresh()
        persistTail()
    }

    private func applyMetadata(from data: [String: Any]) {
        // Host shape: kind=metadata, session=<key string>, revision, summary=<SessionSummary>.
        guard let summaryDict = data["summary"] as? [String: Any],
              let summary = try? RemoteJSONDecoder.decode(SessionSummary.self, from: summaryDict)
        else { return }
        attentionRevision += 1
        let wasWorking = isAssistantWorking
        applyAuthoritativeAttention(summary.attention)
        if wasWorking, !isAssistantWorking { requestCatchUp() }
        if summary.live != isLive {
            isLive = summary.live
        }
        onSessionMetadata?(summary, SessionListStore.revision(from: data))
    }

    private func merge(_ incoming: [RichMessage]) {
        let beforeIDs = Set(messages.compactMap(\.commandID))
        let combined = ConversationMessageMerge.combining(messages, with: incoming)
        if combined != messages {
            messages = combined
        }
        let newest = max(newestSequence, newestOfficialSeq)
        if newest != newestSequence {
            newestSequence = newest
        }
        let oldestOfficial = oldestOfficialSeq
        if oldestSequence == 0 {
            if oldestOfficial != oldestSequence {
                oldestSequence = oldestOfficial
            }
        } else if oldestOfficial > 0 {
            let floored = min(oldestSequence, oldestOfficial)
            if floored != oldestSequence {
                oldestSequence = floored
            }
        }
        extractOptionsFromMessages()
        // Official transcript consumed a local echo — drop resolved pending metadata.
        let afterIDs = Set(messages.compactMap(\.commandID))
        let consumed = beforeIDs.subtracting(afterIDs)
        for commandID in consumed where !hostID.isEmpty {
            PendingCommandStore.remove(hostID: hostID, commandID: commandID)
        }
    }

    private var newestOfficialSeq: Int {
        messages.lazy.map(\.seq).filter { $0 > 0 }.max() ?? 0
    }

    private var oldestOfficialSeq: Int {
        messages.lazy.map(\.seq).filter { $0 > 0 }.min() ?? 0
    }

    private func allocateLocalSeq() -> Int {
        let seq = nextLocalSeq
        if nextLocalSeq > Int.min {
            nextLocalSeq -= 1
        }
        return seq
    }

    private func restoreLocalSeqCursor() {
        let minLocal = messages.lazy.map(\.seq).filter { $0 < 0 }.min() ?? 0
        if minLocal < 0 {
            nextLocalSeq = minLocal - 1
        }
    }

    private func updateLocalDelivery(
        _ delivery: MessageDelivery,
        text: String? = nil,
        seq: Int? = nil,
        commandID: String? = nil,
        failureDetail: String? = nil
    ) {
        let needle = text.map { ConversationMessageMerge.normalizedText($0) }
        for index in messages.indices.reversed() {
            let message = messages[index]
            guard message.isLocal else { continue }
            if let seq, message.seq != seq { continue }
            if let commandID, message.commandID != commandID { continue }
            if let needle, ConversationMessageMerge.normalizedText(message.text) != needle { continue }
            messages[index].delivery = delivery
            if let failureDetail {
                messages[index].failureDetail = failureDetail
            } else if delivery == .sent || delivery == .pending || delivery == .accepted {
                messages[index].failureDetail = nil
            }
            return
        }
    }

    private func applyAttention(from data: [String: Any]) {
        let raw = ((data["attention"] as? String) ?? "none")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = AttentionKind(rawValue: raw) ?? .none
        // Host hint right after input was injected: not an authoritative state, so it
        // neither bumps the snapshot guard nor overwrites `attention`.
        if (data["provisional"] as? Bool) == true {
            if value == .working, attention != .working, attention != .waiting {
                beginProvisionalWorking()
            }
            return
        }
        attentionRevision += 1
        applyAuthoritativeAttention(value)
        if attention == .waiting {
            schedulePromptRefresh()
        }
    }

    private func applyEcho(from data: [String: Any]) {
        let rawText: String?
        if let text = data["text"] as? String {
            rawText = text
        } else if let message = data["message"] as? [String: Any] {
            rawText = message["text"] as? String
        } else {
            rawText = nil
        }
        let trimmed = ConversationMessageMerge.normalizedText(rawText)
        guard !trimmed.isEmpty else { return }

        let echoCommandID = (data["command_id"] as? String)
            ?? ((data["message"] as? [String: Any])?["command_id"] as? String)

        if let index = messages.lastIndex(where: { message in
            if let echoCommandID, let localID = message.commandID, !echoCommandID.isEmpty {
                return message.isLocal && localID == echoCommandID
            }
            return message.isLocal
                && message.role.lowercased() == "user"
                && ConversationMessageMerge.normalizedText(message.text) == trimmed
        }) {
            // Prefer honest receipt progression when capability is on; otherwise legacy sent.
            if supportsCommandReceipts {
                if messages[index].delivery == .pending {
                    messages[index].delivery = .accepted
                }
            } else {
                messages[index].delivery = .sent
            }
            if let echoCommandID, messages[index].commandID == nil {
                messages[index].commandID = echoCommandID
            }
            return
        }
        if messages.contains(where: { message in
            message.seq > 0
                && message.role.lowercased() == "user"
                && ConversationMessageMerge.normalizedText(message.text) == trimmed
        }) {
            return
        }
        let seq = allocateLocalSeq()
        messages.append(
            RichMessage(
                seq: seq,
                role: "user",
                text: trimmed,
                delivery: supportsCommandReceipts ? .accepted : .sent,
                timestamp: Date().timeIntervalSince1970,
                commandID: echoCommandID,
                localAfterSeq: newestOfficialSeq
            )
        )
    }

    private func persistTail() {
        guard !hostID.isEmpty else { return }
        // Persist every synchronized official page (incl. Load earlier), then bound + recompute cursors.
        // Keep tool bodies out of the reopen cache so warm paint stays text-first.
        let slimMessages = messages.map { message in
            guard let tools = message.tools, !tools.isEmpty else { return message }
            var copy = message
            copy.tools = tools.map { $0.strippingBodies() }
            return copy
        }
        var snapshot = ConversationHistoryBudget.snapshot(
            hostID: hostID,
            sessionKey: sessionKey,
            messages: slimMessages,
            hasMoreHistory: hasMoreHistory,
            generation: generation
        )
        snapshot.forkMessages = forkMessages
        ConversationTailCache.save(snapshot)
        let retainedSeqs = Set(snapshot.messages.map(\.seq))
        // Only the saved cache is bounded. Trimming the open conversation would drop
        // a just-loaded earlier page and make automatic loading fetch it forever.
        guard !messages.contains(where: { $0.seq > 0 && !retainedSeqs.contains($0.seq) }) else { return }
        // Keep in-memory cursors aligned with what was actually retained.
        if snapshot.oldestSequence > 0, snapshot.oldestSequence != oldestSequence {
            oldestSequence = snapshot.oldestSequence
        }
        if snapshot.newestSequence > 0, snapshot.newestSequence != newestSequence {
            newestSequence = snapshot.newestSequence
        }
        if snapshot.hasMoreHistory != hasMoreHistory {
            hasMoreHistory = snapshot.hasMoreHistory
        }
    }

    /// Fetch tool bodies for merged activity cards (one or more host message seqs).
    @discardableResult
    func fetchToolDetails(sourceSeqs: [Int]) async -> [ToolCall]? {
        let seqs = sourceSeqs.filter { $0 > 0 }
        guard !seqs.isEmpty else { return nil }
        var combined: [ToolCall] = []
        var anyFound = false
        for seq in seqs {
            if let tools = await fetchToolDetails(messageSeq: seq) {
                anyFound = true
                combined.append(contentsOf: tools)
            }
        }
        return anyFound ? combined : nil
    }

    /// Fetch tool bodies for one history message when the activity sheet opens.
    @discardableResult
    func fetchToolDetails(messageSeq: Int) async -> [ToolCall]? {
        guard forkMessages == nil, messageSeq > 0, !hasStopped,
              let index = messages.firstIndex(where: { $0.seq == messageSeq }) else { return nil }
        let existing = messages[index].tools ?? []
        if !existing.isEmpty, existing.allSatisfy({ !$0.needsDetailFetch }) {
            return existing
        }
        guard let client else { return existing.isEmpty ? nil : existing }
        let historyGeneration = generation
        let lifecycle = lifecycleRevision
        do {
            let response: SessionToolDetailResponse
#if DEBUG
            if let request = toolDetailRequestForTesting {
                response = try await request(messageSeq)
            } else {
                response = try await requestToolDetails(client, messageSeq: messageSeq)
            }
#else
            response = try await requestToolDetails(client, messageSeq: messageSeq)
#endif
            try Task.checkCancellation()
            guard !hasStopped, lifecycle == lifecycleRevision, generation == historyGeneration,
                  response.seq == 0 || response.seq == messageSeq,
                  let currentIndex = messages.firstIndex(where: { $0.seq == messageSeq })
            else { return nil }
            let current = messages[currentIndex].tools ?? []
            if let reason = response.unavailable, !reason.isEmpty, response.tools.isEmpty {
                return current.isEmpty ? nil : current
            }
            let details = Dictionary(response.tools.map { ($0.callID, $0) }, uniquingKeysWith: { _, latest in latest })
            let requested = Dictionary(existing.map { ($0.callID, $0) }, uniquingKeysWith: { _, latest in latest })
            let merged: [ToolCall]
            if existing.isEmpty, current.isEmpty {
                var seen = Set<String>()
                merged = response.tools.filter { seen.insert($0.callID).inserted }.compactMap { details[$0.callID] }
            } else {
                merged = current.map { tool in
                    guard let original = requested[tool.callID],
                          tool.strippingBodies() == original.strippingBodies(),
                          let detail = details[tool.callID] else { return tool }
                    return tool.mergingDetail(from: detail)
                }
            }
            messages[currentIndex].tools = merged
            return merged
        } catch {
            guard !hasStopped, lifecycle == lifecycleRevision, generation == historyGeneration,
                  let current = messages.first(where: { $0.seq == messageSeq })?.tools else { return nil }
            return current.isEmpty ? nil : current
        }
    }

    private func requestToolDetails(_ client: RemoteClient, messageSeq: Int) async throws -> SessionToolDetailResponse {
        try await client.call(
            WireProtocol.mSessionToolDetail,
            params: ["key": sessionKey, "seq": messageSeq, "limit": 32],
            as: SessionToolDetailResponse.self
        )
    }

    private func schedulePromptRefresh() {
        promptRefreshTask?.cancel()
        promptRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.loadPrompts()
        }
    }
}
