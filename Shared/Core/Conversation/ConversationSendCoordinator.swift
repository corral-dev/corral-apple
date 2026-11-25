import Foundation

// Send-flow coordinator: outbound text / image / question logic extracted from
// SessionDetailView (2026-10-01 refactor) so a future iPad split view or Mac
// window can reuse it. Foundation-only: no UIKit / SwiftUI imports, so this
// compiles in the portable SPM package. Haptics and all UI state stay in the
// view: the coordinator reports outcomes through ConversationSendDisplay and
// the view emits the same HapticFeedback events as before.

/// Portable staged image: identity + payload + receipt id. The Xcode-only
/// `DraftImageAttachment` (which carries a `UIImage` preview) maps to and
/// from this at the view boundary.
struct StagedSendImage: Sendable, Equatable, Identifiable {
    var id: UUID
    var base64: String
    var commandID: String?
}

struct StagedSendFile: Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var data: Data
    var commandID: String?
}

/// Haptic outcome the coordinator reports. The view maps each case onto the
/// same `HapticFeedback` event it emitted before the extraction.
enum ConversationSendHaptic: Sendable, Equatable {
    case committed
    case success
    case error
    case warning
}

/// The store surface the send flow needs. `ConversationStore` conforms by its
/// existing API (see the extension below); tests inject a fake.
@MainActor
protocol ConversationSendStore: AnyObject {
    var supportsCommandReceipts: Bool { get }
    var supportsInputFile: Bool { get }
    var messages: [RichMessage] { get }
    var prompts: [SessionPrompt] { get }
    var questionSubmissionState: NativeQuestionSubmissionState? { get }
    var questionFailureIsUncertain: Bool { get }
    @discardableResult
    func enqueueLocalUser(
        _ text: String,
        commandID: String?,
        reusingSeq: Int?,
        images: [Data],
        files: [LocalFileAttachment]
    ) -> Int
    func recordPendingCommand(commandID: String, text: String, localSeq: Int)
    func applyCommandStatus(commandID: String, status: String, failureDetail: String?)
    func markLocalSent(text: String?, seq: Int?)
    func markLocalFailed(text: String?, seq: Int?, failureDetail: String?)
    func markLocalNeedsReview(text: String?, seq: Int?, failureDetail: String?)
    func sendText(
        _ text: String, submit: Bool, commandID: String?, ownCommandIDs: [String]
    ) async throws
    func sendImage(
        base64: String, commandID: String?, ownCommandIDs: [String]
    ) async throws
    func sendFile(
        filename: String, data: Data, commandID: String?, ownCommandIDs: [String]
    ) async throws
    func submitQuestion(requestID: String, answers: [NativeQuestionAnswer]) async
}

extension ConversationStore: ConversationSendStore {}

/// UI state the send flow mutates. Implemented by the view (which owns draft,
/// attachments, scroll requests, error banner, haptics and the busy flag).
/// Every method is synchronous: the coordinator calls them inline, in the same
/// order the view code did before the extraction.
@MainActor
protocol ConversationSendDisplay: AnyObject {
    var composerDraft: String { get set }
    func setSending(_ sending: Bool)
    func scrollToLatest()
    func clearPersistedDraft()
    func persistDraft(_ text: String)
    func showError(_ message: String, haptic: ConversationSendHaptic?, operationID: UUID?)
    func clearError()
    func emitHaptic(_ haptic: ConversationSendHaptic, operationID: UUID?)
    func beginHapticOperation() -> UUID
    /// Hands the failed / not-yet-attempted images back to the composer.
    /// The view maps them onto its preview-carrying attachments.
    func restoreImages(_ images: [StagedSendImage])
    /// Hands the failed / not-yet-attempted files back to the composer.
    func restoreFiles(_ files: [StagedSendFile])
    /// The open question owns the host keyboard: point at it instead of sending.
    func showQuestionPending()
}

/// Synchronous plan for one text send. Built by `beginTextSend` (same runloop
/// as the tap, so the `isSending` exclusion cannot race); run by
/// `runTextSend` inside a Task, which releases that exclusion at once because
/// the store sends in tap order behind earlier messages.
struct TextSendPlan: Sendable {
    let payload: String
    let commandID: String?
    let localSeq: Int?
    let useReceipts: Bool
    /// Mirrors `clearDraftOnStart`: only a send that cleared the composer
    /// restores its payload on failure.
    let restoreDraftOnFailure: Bool
    let operationID: UUID
}

/// Outcome of running a staged outbound send plan.
enum ComposerSendOutcome: Equatable, Sendable {
    case sent
    case failed(String)
}

/// Result of attempting to dispatch a queued follow-up item without altering the live draft.
enum QueuedComposerStart: Sendable {
    case dispatched(ComposerSendPlan)
    case blockedByQuestion
    case rejected(String)
    case deferred
}

/// Synchronous plan for one composer send (one bubble: its images, then its text).
struct ComposerSendPlan: Sendable {
    let images: [StagedSendImage]
    let files: [StagedSendFile]
    let text: TextSendPlan?
    let trimmedText: String
    let hasText: Bool
    /// The single optimistic bubble that stands for this whole send (owner
    /// correction 2026-11-15: one send is one bubble, never text + `[image]`).
    let echoSeq: Int?
    let operationID: UUID
    let restoreDraftOnFailure: Bool

    /// Every receipt identity this send owns: its images, files, and its text.
    /// The outbound queue must not wait on its own optimistic bubble.
    var ownCommandIDs: [String] {
        images.compactMap(\.commandID)
            + files.compactMap(\.commandID)
            + [text?.commandID].compactMap { $0 }
    }
}

/// Synchronous plan for one native question submission.
struct QuestionSendPlan: Sendable {
    let requestID: String
    let answers: [NativeQuestionAnswer]
    let operationID: UUID
}

@MainActor
struct ConversationSendCoordinator: Sendable {
    init() {}

    // MARK: - Composer draft (images first, then optional text)

    /// Gate + synchronous start effects. Returns nil when the exclusion gate
    /// blocks (the view does nothing) or when the offline path already applied
    /// the draft restore + error. Otherwise the caller must pass the plan to
    /// `runComposerSend` inside a Task.
    func beginComposerSend(
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay,
        text: String,
        images: [StagedSendImage],
        files: [StagedSendFile] = [],
        isBusy: Bool,
        isHostReady: Bool
    ) -> ComposerSendPlan? {
        guard ComposerSendPolicy.canSend(
            text: text,
            attachmentCount: images.count + files.count,
            isBusy: isBusy
        ) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        guard isHostReady, let store else {
            display.composerDraft = ComposerSendPolicy.restoredDraft(
                failedText: trimmed,
                currentDraft: display.composerDraft
            )
            display.restoreImages(images)
            display.restoreFiles(files)
            display.showError(notConnectedMessage, haptic: .error, operationID: nil)
            return nil
        }
        if PendingQuestionGate.blocksInput(store.prompts, submission: store.questionSubmissionState) {
            // Nothing leaves the composer: no bubble the host would refuse.
            display.composerDraft = ComposerSendPolicy.restoredDraft(
                failedText: trimmed,
                currentDraft: display.composerDraft
            )
            display.restoreImages(images)
            display.restoreFiles(files)
            display.showQuestionPending()
            return nil
        }
        if !files.isEmpty && !store.supportsInputFile {
            display.composerDraft = ComposerSendPolicy.restoredDraft(
                failedText: trimmed,
                currentDraft: display.composerDraft
            )
            display.restoreImages(images)
            display.restoreFiles(files)
            display.showError(
                String(localized: "composer.file_host_unsupported"),
                haptic: .error,
                operationID: nil
            )
            return nil
        }
        return stageComposerSend(
            store: store,
            display: display,
            trimmed: trimmed,
            hasText: hasText,
            images: images,
            files: files,
            isBusy: isBusy,
            isHostReady: isHostReady,
            clearDraftOnStart: true
        )
    }

    func beginQueuedComposerSend(
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay,
        text: String,
        images: [StagedSendImage],
        files: [StagedSendFile] = [],
        isBusy: Bool,
        isHostReady: Bool
    ) -> QueuedComposerStart {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        guard hasText || !images.isEmpty || !files.isEmpty,
              ComposerSendPolicy.canSend(
                text: text,
                attachmentCount: images.count + files.count,
                isBusy: isBusy
              ),
              isHostReady,
              let store else {
            return .deferred
        }
        if PendingQuestionGate.blocksInput(store.prompts, submission: store.questionSubmissionState) {
            return .blockedByQuestion
        }
        if !files.isEmpty && !store.supportsInputFile {
            return .rejected(String(localized: "composer.file_host_unsupported"))
        }
        guard let plan = stageComposerSend(
            store: store,
            display: display,
            trimmed: trimmed,
            hasText: hasText,
            images: images,
            files: files,
            isBusy: isBusy,
            isHostReady: isHostReady,
            clearDraftOnStart: false
        ) else {
            return .deferred
        }
        return .dispatched(plan)
    }

    private func stageComposerSend(
        store: any ConversationSendStore,
        display: any ConversationSendDisplay,
        trimmed: String,
        hasText: Bool,
        images: [StagedSendImage],
        files: [StagedSendFile],
        isBusy: Bool,
        isHostReady: Bool,
        clearDraftOnStart: Bool
    ) -> ComposerSendPlan? {
        if images.isEmpty && files.isEmpty, hasText {
            return beginTextSend(
                trimmed,
                store: store,
                display: display,
                reuseCommandID: nil,
                reuseSeq: nil,
                clearDraftOnStart: clearDraftOnStart,
                isBusy: isBusy,
                isHostReady: isHostReady
            ).map { textPlan in
                ComposerSendPlan(
                    images: [],
                    files: [],
                    text: textPlan,
                    trimmedText: trimmed,
                    hasText: true,
                    echoSeq: textPlan.localSeq,
                    operationID: textPlan.operationID,
                    restoreDraftOnFailure: clearDraftOnStart
                )
            }
        }
        display.setSending(true)
        let operationID = display.beginHapticOperation()
        display.emitHaptic(.committed, operationID: operationID)
        display.scrollToLatest()
        let imageDrafts = images.map { image in
            var image = image
            if image.commandID == nil {
                image.commandID = UUID().uuidString
            }
            return image
        }
        let fileDrafts = files.map { file in
            var file = file
            if file.commandID == nil {
                file.commandID = UUID().uuidString
            }
            return file
        }
        // Stage the optimistic echo for the whole send: body text + images + files.
        let payloads = imageDrafts.map { Data(base64Encoded: $0.base64) ?? Data() }
        let localFiles = fileDrafts.map { LocalFileAttachment(name: $0.name, byteCount: $0.data.count) }
        let textPlan = hasText ? prepareTextSend(
            trimmed,
            store: store,
            display: display,
            reuseCommandID: nil,
            reuseSeq: nil,
            clearDraftOnStart: false,
            operationID: operationID,
            images: payloads,
            files: localFiles,
            restoreDraftOnFailure: clearDraftOnStart
        ) : nil
        let echoSeq = textPlan?.localSeq ?? stageAttachmentEcho(
            store: store,
            images: imageDrafts,
            payloads: payloads,
            files: fileDrafts,
            localFiles: localFiles
        )
        if let echoSeq {
            for image in imageDrafts {
                guard let commandID = image.commandID else { continue }
                store.recordPendingCommand(commandID: commandID, text: "", localSeq: echoSeq)
            }
            for file in fileDrafts {
                guard let commandID = file.commandID else { continue }
                store.recordPendingCommand(commandID: commandID, text: "", localSeq: echoSeq)
            }
        }
        return ComposerSendPlan(
            images: imageDrafts,
            files: fileDrafts,
            text: textPlan,
            trimmedText: trimmed,
            hasText: hasText,
            echoSeq: echoSeq,
            operationID: operationID,
            restoreDraftOnFailure: clearDraftOnStart
        )
    }

    /// An attachment-only send still owes the user one bubble while in flight.
    private func stageAttachmentEcho(
        store: any ConversationSendStore,
        images: [StagedSendImage],
        payloads: [Data],
        files: [StagedSendFile],
        localFiles: [LocalFileAttachment]
    ) -> Int? {
        guard !payloads.isEmpty || !localFiles.isEmpty else { return nil }
        let leadCommandID = images.first?.commandID ?? files.first?.commandID
        return store.enqueueLocalUser(
            "",
            commandID: leadCommandID,
            reusingSeq: nil,
            images: payloads,
            files: localFiles
        )
    }

    @discardableResult
    func runComposerSend(
        _ plan: ComposerSendPlan,
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay
    ) async -> ComposerSendOutcome {
        guard let store else {
            display.setSending(false)
            return .failed(notConnectedMessage)
        }
        // The bubble and draft are already staged; the store queues the send behind
        // earlier ones, so the composer accepts the next message right away.
        display.setSending(false)
        // Text-only sends reuse the shared text path (same ordering, same
        // exclusion window, same error mapping as before the extraction).
        if plan.images.isEmpty && plan.files.isEmpty, let textPlan = plan.text {
            return await runTextSend(textPlan, store: store, display: display)
        }
        var sentImageCount = 0
        var sentFileCount = 0
        var textSendStarted = false
        let ownCommandIDs = plan.ownCommandIDs
        do {
            for image in plan.images {
                let commandID = image.commandID
                try await store.sendImage(
                    base64: image.base64, commandID: commandID, ownCommandIDs: ownCommandIDs
                )
                if !store.supportsCommandReceipts, let commandID {
                    store.markLocalSent(text: nil, seq: plan.echoSeq)
                    store.applyCommandStatus(commandID: commandID, status: "delivered", failureDetail: nil)
                }
                sentImageCount += 1
            }
            for file in plan.files {
                let commandID = file.commandID
                try await store.sendFile(
                    filename: file.name, data: file.data, commandID: commandID, ownCommandIDs: ownCommandIDs
                )
                if !store.supportsCommandReceipts, let commandID {
                    store.markLocalSent(text: nil, seq: plan.echoSeq)
                    store.applyCommandStatus(commandID: commandID, status: "delivered", failureDetail: nil)
                }
                sentFileCount += 1
            }
            if let textPlan = plan.text {
                textSendStarted = true
                try await finishTextSend(textPlan, store: store, ownCommandIDs: ownCommandIDs)
            } else {
                // Attachment-only: `input.image` / `input.file` only pastes paths into
                // the host composer; flush with an empty submit turn.
                textSendStarted = true
                try await store.sendText(
                    "", submit: true, commandID: nil, ownCommandIDs: ownCommandIDs
                )
            }
            display.clearError()
            return .sent
        } catch {
            if plan.restoreDraftOnFailure {
                let unsentImages = ComposerSendPolicy.unsentImageSuffix(images: plan.images, sentCount: sentImageCount)
                if !unsentImages.isEmpty {
                    display.restoreImages(unsentImages)
                }
                let unsentFiles = ComposerSendPolicy.unsentImageSuffix(images: plan.files, sentCount: sentFileCount)
                if !unsentFiles.isEmpty {
                    display.restoreFiles(unsentFiles)
                }
            }
            if let textPlan = plan.text {
                let detail = handleOutboundFailure(
                    error,
                    payload: textPlan.payload,
                    commandID: textPlan.commandID,
                    localSeq: textPlan.localSeq,
                    restoreDraft: plan.restoreDraftOnFailure,
                    store: store,
                    display: display,
                    operationID: plan.operationID,
                    wasSent: textSendStarted
                )
                return .failed(detail)
            } else {
                if plan.restoreDraftOnFailure, plan.hasText {
                    display.composerDraft = ComposerSendPolicy.restoredDraft(
                        failedText: plan.trimmedText,
                        currentDraft: display.composerDraft
                    )
                }
                let detail = handleOutboundFailure(
                    error,
                    payload: nil,
                    commandID: nil,
                    localSeq: plan.echoSeq,
                    restoreDraft: false,
                    store: store,
                    display: display,
                    operationID: plan.operationID
                )
                return .failed(detail)
            }
        }
    }

    // MARK: - Text send

    /// Shared send path. `reuseCommandID` keeps the same durable id on
    /// needsReview retry.
    func beginTextSend(
        _ text: String,
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay,
        reuseCommandID: String?,
        reuseSeq: Int?,
        clearDraftOnStart: Bool,
        isBusy: Bool,
        isHostReady: Bool
    ) -> TextSendPlan? {
        guard let payload = ComposerSendPolicy.trimmedSendableText(text, isBusy: isBusy) else { return nil }
        guard isHostReady, let store else {
            // A bubble retry (clearDraftOnStart == false) never removed composer
            // text, so its offline failure must leave the draft untouched.
            display.composerDraft = ComposerSendPolicy.restoredDraft(
                failedText: payload,
                currentDraft: display.composerDraft,
                didClearComposer: clearDraftOnStart
            )
            display.showError(notConnectedMessage, haptic: .error, operationID: nil)
            return nil
        }
        if PendingQuestionGate.blocksInput(store.prompts, submission: store.questionSubmissionState) {
            display.composerDraft = ComposerSendPolicy.restoredDraft(
                failedText: payload,
                currentDraft: display.composerDraft,
                didClearComposer: clearDraftOnStart
            )
            display.showQuestionPending()
            return nil
        }
        display.setSending(true)
        let operationID = display.beginHapticOperation()
        let plan = prepareTextSend(
            payload,
            store: store,
            display: display,
            reuseCommandID: reuseCommandID,
            reuseSeq: reuseSeq,
            clearDraftOnStart: clearDraftOnStart,
            operationID: operationID
        )
        display.emitHaptic(.committed, operationID: operationID)
        return plan
    }

    @discardableResult
    func runTextSend(
        _ plan: TextSendPlan,
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay
    ) async -> ComposerSendOutcome {
        guard let store else {
            display.setSending(false)
            return .failed(notConnectedMessage)
        }
        // Staged and queued in the store's outgoing order: free the composer now.
        display.setSending(false)
        do {
            try await finishTextSend(plan, store: store)
            display.clearError()
            return .sent
        } catch {
            let detail = handleOutboundFailure(
                error,
                payload: plan.payload,
                commandID: plan.commandID,
                localSeq: plan.localSeq,
                // Bubble retries never cleared the composer: their failure
                // must not prepend the payload onto the live draft.
                restoreDraft: plan.restoreDraftOnFailure,
                store: store,
                display: display,
                operationID: plan.operationID
            )
            return .failed(detail)
        }
    }

    private func prepareTextSend(
        _ text: String,
        store: any ConversationSendStore,
        display: any ConversationSendDisplay,
        reuseCommandID: String?,
        reuseSeq: Int?,
        clearDraftOnStart: Bool,
        operationID: UUID,
        images: [Data] = [],
        files: [LocalFileAttachment] = [],
        restoreDraftOnFailure: Bool? = nil
    ) -> TextSendPlan {
        if clearDraftOnStart {
            display.composerDraft = ""
            display.clearPersistedDraft()
        }
        let useReceipts = store.supportsCommandReceipts
        let commandID: String?
        let localSeq: Int?
        if let reuseCommandID, !reuseCommandID.isEmpty {
            commandID = reuseCommandID
            localSeq = reuseSeq
            store.applyCommandStatus(commandID: reuseCommandID, status: "unseen", failureDetail: nil)
        } else {
            // Identity belongs to the user's intent, before hello/capability
            // state can change while this send waits in the outgoing queue.
            commandID = UUID().uuidString
            localSeq = store.enqueueLocalUser(
                text, commandID: commandID, reusingSeq: reuseSeq, images: images, files: files
            )
            if let commandID, let localSeq {
                store.recordPendingCommand(commandID: commandID, text: text, localSeq: localSeq)
            }
        }
        display.scrollToLatest()
        return TextSendPlan(
            payload: text,
            commandID: commandID,
            localSeq: localSeq,
            useReceipts: useReceipts,
            restoreDraftOnFailure: restoreDraftOnFailure ?? clearDraftOnStart,
            operationID: operationID
        )
    }

    private func finishTextSend(
        _ plan: TextSendPlan,
        store: any ConversationSendStore,
        ownCommandIDs: [String] = []
    ) async throws {
        try await store.sendText(
            plan.payload,
            submit: true,
            commandID: plan.commandID,
            ownCommandIDs: ownCommandIDs
        )
        if !store.supportsCommandReceipts {
            store.markLocalSent(text: nil, seq: plan.localSeq)
            if let commandID = plan.commandID {
                store.applyCommandStatus(commandID: commandID, status: "delivered", failureDetail: nil)
            }
        } else if let commandID = plan.commandID,
                  store.messages.first(where: {
                      if let localSeq = plan.localSeq { return $0.seq == localSeq }
                      return $0.commandID == commandID
                  })?.delivery == .pending {
            store.applyCommandStatus(commandID: commandID, status: "accepted", failureDetail: nil)
        }
    }

    // MARK: - Bubble retry

    /// Explicit user retry only — never auto-resends ambiguous command_ids.
    /// needsReview must resend the SAME command_id so the host can dedupe.
    func beginRetrySend(
        _ message: RichMessage,
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay,
        isBusy: Bool,
        isHostReady: Bool
    ) -> TextSendPlan? {
        guard message.delivery == .failed || message.delivery == .needsReview,
              let text = message.text,
              !text.isEmpty else { return nil }
        if message.delivery == .needsReview,
           let commandID = message.commandID,
           !commandID.isEmpty {
            return beginTextSend(
                text,
                store: store,
                display: display,
                reuseCommandID: commandID,
                reuseSeq: message.seq,
                clearDraftOnStart: false,
                isBusy: isBusy,
                isHostReady: isHostReady
            )
        }
        return beginTextSend(
            text,
            store: store,
            display: display,
            reuseCommandID: nil,
            reuseSeq: message.seq,
            clearDraftOnStart: false,
            isBusy: isBusy,
            isHostReady: isHostReady
        )
    }

    // MARK: - Failure mapping

    @discardableResult
    private func handleOutboundFailure(
        _ error: Error,
        payload: String?,
        commandID: String?,
        localSeq: Int?,
        restoreDraft: Bool,
        store: any ConversationSendStore,
        display: any ConversationSendDisplay,
        operationID: UUID,
        wasSent: Bool = true
    ) -> String {
        let status = wasSent ? PendingCommandStore.hostStatusAfterSendFailure(error) : "rejected"
        let existing = store.messages.first(where: { message in
            if let localSeq { return message.seq == localSeq }
            return commandID != nil && message.commandID == commandID
        })?.failureDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thrownDetail = (error as? RemoteCallError)?.message ?? error.localizedDescription
        let detail = existing?.isEmpty == false ? existing! : thrownDetail
        if let commandID {
            store.applyCommandStatus(commandID: commandID, status: status, failureDetail: detail)
        } else if status == "rejected" {
            store.markLocalFailed(text: nil, seq: localSeq, failureDetail: detail)
        } else {
            store.markLocalNeedsReview(text: nil, seq: localSeq, failureDetail: detail)
        }
        if restoreDraft, let payload {
            display.composerDraft = ComposerSendPolicy.restoredDraft(
                failedText: payload,
                currentDraft: display.composerDraft
            )
            display.persistDraft(display.composerDraft)
        }
        let hasMessageFeedback = store.messages.contains { message in
            if let localSeq { return message.seq == localSeq }
            return commandID != nil && message.commandID == commandID
        }
        let haptic: ConversationSendHaptic = status == "rejected" ? .error : .warning
        if hasMessageFeedback {
            display.clearError()
            display.emitHaptic(haptic, operationID: operationID)
        } else {
            display.showError(detail, haptic: haptic, operationID: operationID)
        }
        return detail
    }

    // MARK: - Native question submission

    func beginQuestionSubmit(
        requestID: String,
        answers: [NativeQuestionAnswer],
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay,
        isBusy: Bool,
        isHostReady: Bool
    ) -> QuestionSendPlan? {
        guard !isBusy, isHostReady, store != nil else { return nil }
        display.setSending(true)
        let operationID = display.beginHapticOperation()
        display.emitHaptic(.committed, operationID: operationID)
        return QuestionSendPlan(requestID: requestID, answers: answers, operationID: operationID)
    }

    func runQuestionSubmit(
        _ plan: QuestionSendPlan,
        store: (any ConversationSendStore)?,
        display: any ConversationSendDisplay
    ) async {
        guard let store else {
            display.setSending(false)
            return
        }
        defer { display.setSending(false) }
        await store.submitQuestion(requestID: plan.requestID, answers: plan.answers)
        switch store.questionSubmissionState?.status {
        case .failed:
            display.emitHaptic(
                store.questionFailureIsUncertain ? .warning : .error,
                operationID: plan.operationID
            )
        case .stale, .unavailable:
            display.emitHaptic(.warning, operationID: plan.operationID)
        default: break
        }
    }

    // MARK: - Shared strings

    private var notConnectedMessage: String {
        String(localized: String.LocalizationValue("error.not_connected"))
    }
}
