import XCTest
@testable import Corral

/// Portable regressions for the send flow extracted from SessionDetailView.
/// A fake store (scripted network, in-memory bubbles) and a recording display
/// prove ordering, exclusion, receipt/command_id reuse, draft restore and
/// haptic outcomes with no network.
@MainActor
final class ConversationSendCoordinatorTests: XCTestCase {
    private var coordinator: ConversationSendCoordinator!
    private var store: FakeSendStore!
    private var display: FakeSendDisplay!

    override func setUp() async throws {
        try await super.setUp()
        coordinator = ConversationSendCoordinator()
        store = FakeSendStore()
        display = FakeSendDisplay()
    }

    func testHostFailureCauseStaysOnBubbleWithoutReceipts() async {
        store.supportsCommandReceipts = false
        store.sendTextError = RemoteCallError(code: "unavailable", message: "Assistant could not resume", hint: "")
        let plan = coordinator.beginTextSend("hello", store: store, display: display,
            reuseCommandID: nil, reuseSeq: nil, clearDraftOnStart: true,
            isBusy: false, isHostReady: true)!
        await coordinator.runTextSend(plan, store: store, display: display)
        XCTAssertEqual(store.messages.first?.failureDetail, "Assistant could not resume")
        XCTAssertEqual(store.messages.first?.delivery, .failed)
    }

    func testReceiptCauseWinsOverGenericThrownError() async {
        store.supportsCommandReceipts = true
        let plan = coordinator.beginTextSend("hello", store: store, display: display,
            reuseCommandID: nil, reuseSeq: nil, clearDraftOnStart: true,
            isBusy: false, isHostReady: true)!
        store.messages[0].failureDetail = "Actual host rejection"
        store.sendTextError = RemoteCallError(code: "unavailable", message: "Generic error", hint: "")
        await coordinator.runTextSend(plan, store: store, display: display)
        XCTAssertEqual(store.messages.first?.failureDetail, "Actual host rejection")
        XCTAssertTrue(display.errors.isEmpty)
        XCTAssertEqual(display.haptics.last?.haptic, .error)
    }

    // MARK: - Text send

    func testTextSendSuccessClearsDraftAndError() async {
        store.supportsCommandReceipts = true
        display.composerDraft = "  hello  "

        guard let plan = coordinator.beginTextSend(
            "  hello  ",
            store: store, display: display,
            reuseCommandID: nil, reuseSeq: nil, clearDraftOnStart: true,
            isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }
        XCTAssertEqual(plan.payload, "hello")
        XCTAssertEqual(display.sendingStates, [true])
        XCTAssertEqual(display.composerDraft, "")
        XCTAssertEqual(display.clearedPersistedCount, 1)
        XCTAssertEqual(display.scrollCount, 1)
        XCTAssertEqual(display.haptics.map(\.haptic), [.committed])

        await coordinator.runTextSend(plan, store: store, display: display)

        XCTAssertEqual(store.sentTexts.count, 1)
        XCTAssertEqual(store.sentTexts.first?.text, "hello")
        let commandID = try? XCTUnwrap(store.sentTexts.first?.commandID)
        XCTAssertEqual(store.recordedPending.map(\.commandID), [commandID])
        XCTAssertEqual(store.messageDelivery(forSeq: plan.localSeq), .accepted)
        XCTAssertEqual(display.clearedErrorCount, 1)
        XCTAssertTrue(display.errors.isEmpty)
        XCTAssertEqual(display.sendingStates, [true, false])
    }

    func testBusySendIsBlockedWithNoSideEffects() {
        let plan = coordinator.beginTextSend(
            "hello",
            store: store, display: display,
            reuseCommandID: nil, reuseSeq: nil, clearDraftOnStart: true,
            isBusy: true, isHostReady: true
        )
        XCTAssertNil(plan)
        XCTAssertTrue(store.sentTexts.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(display.isIdle)
    }

    func testOfflineTextSendRestoresDraftAndShowsError() {
        display.composerDraft = ""
        let plan = coordinator.beginTextSend(
            "hello",
            store: nil, display: display,
            reuseCommandID: nil, reuseSeq: nil, clearDraftOnStart: true,
            isBusy: false, isHostReady: false
        )
        XCTAssertNil(plan)
        XCTAssertEqual(display.composerDraft, "hello")
        XCTAssertEqual(display.errors.count, 1)
        XCTAssertEqual(display.errors.first?.haptic, .error)
        XCTAssertNil(display.errors.first?.operationID)
        XCTAssertTrue(display.sendingStates.isEmpty)
        XCTAssertTrue(display.haptics.isEmpty)
    }

    func testSendFailureRestoresPayloadBeforeNewerDraft() async {
        store.supportsCommandReceipts = false
        store.sendTextError = URLError(.timedOut)
        display.composerDraft = ""

        guard let plan = coordinator.beginTextSend(
            "First message",
            store: store, display: display,
            reuseCommandID: nil, reuseSeq: nil, clearDraftOnStart: true,
            isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }
        // The user keeps typing while the send is in flight.
        display.composerDraft = "Next message"

        await coordinator.runTextSend(plan, store: store, display: display)

        XCTAssertEqual(display.composerDraft, "First message\nNext message")
        XCTAssertEqual(display.persistedDrafts.last, "First message\nNext message")
        XCTAssertEqual(store.messageDelivery(forSeq: plan.localSeq), .needsReview)
        XCTAssertTrue(display.errors.isEmpty)
        XCTAssertEqual(display.haptics.last?.haptic, .warning)
        XCTAssertEqual(display.haptics.last?.operationID, plan.operationID)
    }

    func testAuthoritativeFailureMarksBubbleFailedWithErrorHaptic() async {
        store.supportsCommandReceipts = true
        store.sendTextError = RemoteCallError(code: "rejected", message: "host says no", hint: "")

        guard let plan = coordinator.beginTextSend(
            "hello",
            store: store, display: display,
            reuseCommandID: nil, reuseSeq: nil, clearDraftOnStart: true,
            isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }

        await coordinator.runTextSend(plan, store: store, display: display)

        XCTAssertEqual(store.messageDelivery(forSeq: plan.localSeq), .failed)
        XCTAssertEqual(store.messages.first?.failureDetail, "host says no")
        XCTAssertTrue(display.errors.isEmpty)
        XCTAssertEqual(display.haptics.last?.haptic, .error)
        XCTAssertEqual(display.composerDraft, "hello")
    }

    // MARK: - Bubble retry

    func testBubbleRetryFailureLeavesDraftUntouched() async throws {
        store.supportsCommandReceipts = false
        store.sendTextError = URLError(.timedOut)
        store.appendLocal(text: "A", delivery: .failed, commandID: nil)
        display.composerDraft = "A\nB"

        let failed = try XCTUnwrap(store.messages.first)
        guard let plan = coordinator.beginRetrySend(
            failed, store: store, display: display, isBusy: false, isHostReady: true
        ) else { return XCTFail("retry must start") }

        await coordinator.runTextSend(plan, store: store, display: display)

        // The retry never cleared the composer, so its failure must not
        // prepend the payload onto the live draft.
        XCTAssertEqual(display.composerDraft, "A\nB")
        XCTAssertTrue(display.persistedDrafts.isEmpty)
    }

    func testRejectedRetryUpdatesOriginalBubbleWithNewReceipt() async throws {
        store.supportsCommandReceipts = true
        store.appendLocal(text: "retry me", delivery: .failed, commandID: "rejected-id")
        store.messages[0].failureDetail = "Old cause"
        let failed = store.messages[0]
        let plan = try XCTUnwrap(coordinator.beginRetrySend(
            failed, store: store, display: display, isBusy: false, isHostReady: true
        ))
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(plan.localSeq, failed.seq)
        XCTAssertNotEqual(plan.commandID, "rejected-id")
        XCTAssertNil(store.messages[0].failureDetail)
        await coordinator.runTextSend(plan, store: store, display: display)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].delivery, .accepted)
    }

    func testNeedsReviewRetryReusesSameCommandID() async throws {
        store.supportsCommandReceipts = true
        store.appendLocal(text: "retry me", delivery: .needsReview, commandID: "cmd-1")
        display.composerDraft = "unrelated"

        let bubble = try XCTUnwrap(store.messages.first)
        guard let plan = coordinator.beginRetrySend(
            bubble, store: store, display: display, isBusy: false, isHostReady: true
        ) else { return XCTFail("retry must start") }
        XCTAssertEqual(plan.commandID, "cmd-1")
        // The retry marks the existing bubble unseen instead of enqueueing new.
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.appliedStatuses.first?.commandID, "cmd-1")
        XCTAssertEqual(store.appliedStatuses.first?.status, "unseen")

        await coordinator.runTextSend(plan, store: store, display: display)

        XCTAssertEqual(store.sentTexts.map(\.commandID), ["cmd-1"])
        XCTAssertEqual(display.composerDraft, "unrelated")
    }

    func testRetryIgnoresNonFailedBubbles() {
        store.appendLocal(text: "sent already", delivery: .sent, commandID: nil)
        let plan = coordinator.beginRetrySend(
            store.messages[0], store: store, display: display, isBusy: false, isHostReady: true
        )
        XCTAssertNil(plan)
        XCTAssertTrue(display.isIdle)
    }

    // MARK: - Composer with images

    func testImagesSendBeforeText() async {
        store.supportsCommandReceipts = true
        let images = [
            StagedSendImage(id: UUID(), base64: "a", commandID: nil),
            StagedSendImage(id: UUID(), base64: "b", commandID: nil),
        ]

        guard let plan = coordinator.beginComposerSend(
            store: store, display: display, text: "caption",
            images: images, isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }
        // Receipt command IDs are assigned at stage time.
        XCTAssertEqual(plan.images.compactMap(\.commandID).count, 2)
        XCTAssertNotNil(plan.text)

        await coordinator.runComposerSend(plan, store: store, display: display)

        XCTAssertEqual(store.orderedEvents, ["image:a", "image:b", "text:caption"])
        // Image command IDs travel with the upload calls.
        XCTAssertEqual(
            store.sentImages.map(\.commandID),
            plan.images.map(\.commandID)
        )
        XCTAssertEqual(store.sentTexts.first?.commandID, plan.text?.commandID)
        XCTAssertTrue(display.restoredImageBatches.isEmpty)
        XCTAssertEqual(display.clearedErrorCount, 1)
    }

    func testPartialImageFailureRestoresOnlyUnsentSuffix() async throws {
        store.supportsCommandReceipts = true
        store.sendImageErrors = [nil, URLError(.timedOut)]
        let images = [
            StagedSendImage(id: UUID(), base64: "a", commandID: nil),
            StagedSendImage(id: UUID(), base64: "b", commandID: nil),
            StagedSendImage(id: UUID(), base64: "c", commandID: nil),
        ]

        guard let plan = coordinator.beginComposerSend(
            store: store, display: display, text: "caption",
            images: images, isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }

        await coordinator.runComposerSend(plan, store: store, display: display)

        // Only the first image was acknowledged; the failed plus unattempted
        // suffix returns, keeping staged receipt IDs for an idempotent retry.
        XCTAssertEqual(display.restoredImageBatches.count, 1)
        let restored = try XCTUnwrap(display.restoredImageBatches.first)
        XCTAssertEqual(restored.map(\.base64), ["b", "c"])
        XCTAssertEqual(restored.map(\.commandID), [plan.images[1].commandID, plan.images[2].commandID])
        XCTAssertEqual(store.sentImages.count, 2)
        // Text never started, so it is definitely unsent: bubble rejected and
        // the payload returns to the composer.
        XCTAssertTrue(store.sentTexts.isEmpty)
        XCTAssertEqual(
            store.messageDelivery(forSeq: plan.text?.localSeq),
            .failed
        )
        XCTAssertEqual(display.composerDraft, "caption")
    }

    func testComposerOfflineRestoresTextAndImages() {
        display.composerDraft = ""
        let images = [StagedSendImage(id: UUID(), base64: "a", commandID: nil)]
        let plan = coordinator.beginComposerSend(
            store: nil, display: display, text: "hello",
            images: images, isBusy: false, isHostReady: false
        )
        XCTAssertNil(plan)
        XCTAssertEqual(display.composerDraft, "hello")
        XCTAssertEqual(display.restoredImageBatches, [images])
        XCTAssertEqual(display.errors.first?.haptic, .error)
    }

    // MARK: - Question submission

    func testQuestionFailureKeepsAnswers() async {
        store.prompts = [FakeSendStore.makePrompt(requestID: "req-1")]
        store.questionError = URLError(.timedOut)
        let answers = [NativeQuestionAnswer(questionID: "q-1", selected: ["0"], text: "")]
        display.composerDraft = "draft stays"

        guard let plan = coordinator.beginQuestionSubmit(
            requestID: "req-1", answers: answers,
            store: store, display: display, isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }

        await coordinator.runQuestionSubmit(plan, store: store, display: display)

        XCTAssertEqual(store.submittedAnswers, [answers])
        XCTAssertEqual(store.questionSubmissionState?.status, .failed(URLError(.timedOut).localizedDescription))
        XCTAssertTrue(store.questionFailureIsUncertain)
        XCTAssertEqual(display.haptics.map(\.haptic), [.committed, .warning])
        // Failure preserves the question draft for an explicit retry: the
        // coordinator clears nothing and leaves the composer alone.
        XCTAssertEqual(display.composerDraft, "draft stays")
        XCTAssertEqual(display.sendingStates, [true, false])
    }

    func testQuestionAuthoritativeFailureEmitsError() async {
        store.prompts = [FakeSendStore.makePrompt(requestID: "req-1")]
        store.questionError = RemoteCallError(code: "rejected", message: "bad answer", hint: "")
        let answers = [NativeQuestionAnswer(questionID: "q-1", selected: ["1"], text: "")]

        guard let plan = coordinator.beginQuestionSubmit(
            requestID: "req-1", answers: answers,
            store: store, display: display, isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }

        await coordinator.runQuestionSubmit(plan, store: store, display: display)

        XCTAssertFalse(store.questionFailureIsUncertain)
        XCTAssertEqual(display.haptics.map(\.haptic), [.committed, .error])
    }

    func testQuestionSubmitBlockedWhileBusy() {
        let plan = coordinator.beginQuestionSubmit(
            requestID: "req-1", answers: [],
            store: store, display: display, isBusy: true, isHostReady: true
        )
        XCTAssertNil(plan)
        XCTAssertTrue(display.isIdle)
    }

    func testStaleQuestionStillCommitsThenWarns() async {
        // Unknown request: the store reports stale, but the committed haptic
        // already fired (matches the pre-extraction ordering).
        store.prompts = [FakeSendStore.makePrompt(requestID: "other")]
        guard let plan = coordinator.beginQuestionSubmit(
            requestID: "req-1", answers: [],
            store: store, display: display, isBusy: false, isHostReady: true
        ) else { return XCTFail("begin must succeed") }

        await coordinator.runQuestionSubmit(plan, store: store, display: display)

        XCTAssertEqual(store.questionSubmissionState?.status, .stale(nil))
        XCTAssertEqual(display.haptics.map(\.haptic), [.committed, .warning])
        XCTAssertTrue(store.submittedAnswers.isEmpty)
    }
}

// MARK: - Fakes

/// In-memory `ConversationSendStore`: scripted network, real status mapping.
@MainActor
final class FakeSendStore: ConversationSendStore {
    var supportsCommandReceipts = false
    var messages: [RichMessage] = []
    var prompts: [SessionPrompt] = []
    var questionSubmissionState: NativeQuestionSubmissionState?
    var questionFailureIsUncertain = false

    var recordedPending: [(commandID: String, text: String, localSeq: Int)] = []
    var appliedStatuses: [(commandID: String, status: String, detail: String?)] = []
    var sentTexts: [(text: String, commandID: String?)] = []
    var sentImages: [(base64: String, commandID: String?)] = []
    var orderedEvents: [String] = []
    var sendTextError: Error?
    var sendImageErrors: [Error?] = []
    var questionError: Error?
    var submittedAnswers: [[NativeQuestionAnswer]] = []

    private var nextLocalSeq = -1

    static func makePrompt(requestID: String) -> SessionPrompt {
        SessionPrompt(id: "p1", name: nil, summary: nil, detail: nil, options: ["A"], requestID: requestID)
    }

    func appendLocal(text: String, delivery: MessageDelivery, commandID: String?) {
        messages.append(
            RichMessage(seq: nextLocalSeq, role: "user", text: text, delivery: delivery, commandID: commandID)
        )
        nextLocalSeq -= 1
    }

    func messageDelivery(forSeq seq: Int?) -> MessageDelivery? {
        messages.first(where: { $0.seq == seq })?.delivery
    }

    func enqueueLocalUser(_ text: String, commandID: String?, reusingSeq: Int?) -> Int {
        if let reusingSeq, let index = messages.firstIndex(where: { $0.seq == reusingSeq && $0.delivery == .failed }) {
            messages[index].delivery = .pending
            messages[index].commandID = commandID
            messages[index].failureDetail = nil
            return reusingSeq
        }
        let seq = nextLocalSeq
        nextLocalSeq -= 1
        messages.append(
            RichMessage(seq: seq, role: "user", text: text, delivery: .pending, commandID: commandID)
        )
        return seq
    }

    func recordPendingCommand(commandID: String, text: String, localSeq: Int) {
        recordedPending.append((commandID, text, localSeq))
    }

    func applyCommandStatus(commandID: String, status: String, failureDetail: String?) {
        appliedStatuses.append((commandID, status, failureDetail))
        let delivery = PendingCommandStore.delivery(fromHostStatus: status)
        for index in messages.indices where messages[index].commandID == commandID {
            messages[index].delivery = delivery
            messages[index].failureDetail = failureDetail
        }
    }

    func markLocalSent(text: String?, seq: Int?) {
        updateLocalDelivery(.sent, seq: seq)
    }

    func markLocalFailed(text: String?, seq: Int?, failureDetail: String?) {
        updateLocalDelivery(.failed, seq: seq, failureDetail: failureDetail)
    }

    func markLocalNeedsReview(text: String?, seq: Int?, failureDetail: String?) {
        updateLocalDelivery(.needsReview, seq: seq, failureDetail: failureDetail)
    }

    private func updateLocalDelivery(_ delivery: MessageDelivery, seq: Int?, failureDetail: String? = nil) {
        for index in messages.indices.reversed() where messages[index].isLocal {
            if let seq, messages[index].seq != seq { continue }
            messages[index].delivery = delivery
            messages[index].failureDetail = failureDetail
            return
        }
    }

    func sendText(_ text: String, submit: Bool, commandID: String?) async throws {
        sentTexts.append((text, commandID))
        orderedEvents.append("text:\(text)")
        if let error = sendTextError { throw error }
    }

    func sendImage(base64: String, commandID: String?) async throws {
        sentImages.append((base64, commandID))
        orderedEvents.append("image:\(base64)")
        if !sendImageErrors.isEmpty {
            let error = sendImageErrors.removeFirst()
            if let error { throw error }
        }
    }

    func submitQuestion(requestID: String, answers: [NativeQuestionAnswer]) async {
        guard prompts.contains(where: { $0.requestID == requestID }) else {
            questionSubmissionState = .init(requestID: requestID, status: .stale(nil))
            return
        }
        // Every attempt carries the full answers payload, including failures:
        // the draft stays available for an explicit retry.
        submittedAnswers.append(answers)
        if let error = questionError {
            let detail = (error as? RemoteCallError)?.message ?? error.localizedDescription
            questionFailureIsUncertain = PendingCommandStore.hostStatusAfterSendFailure(error) != "rejected"
            questionSubmissionState = .init(requestID: requestID, status: .failed(detail))
            return
        }
        questionSubmissionState = .init(requestID: requestID, status: .delivered)
    }
}

/// Recording `ConversationSendDisplay`.
@MainActor
final class FakeSendDisplay: ConversationSendDisplay {
    var composerDraft = ""
    var sendingStates: [Bool] = []
    var scrollCount = 0
    var persistedDrafts: [String] = []
    var clearedPersistedCount = 0
    var errors: [(message: String, haptic: ConversationSendHaptic?, operationID: UUID?)] = []
    var clearedErrorCount = 0
    var haptics: [(haptic: ConversationSendHaptic, operationID: UUID?)] = []
    var operationCount = 0
    var restoredImageBatches: [[StagedSendImage]] = []

    var isIdle: Bool {
        sendingStates.isEmpty && haptics.isEmpty && errors.isEmpty
            && scrollCount == 0 && clearedErrorCount == 0
            && restoredImageBatches.isEmpty && persistedDrafts.isEmpty
            && clearedPersistedCount == 0
    }

    func setSending(_ sending: Bool) { sendingStates.append(sending) }
    func scrollToLatest() { scrollCount += 1 }
    func clearPersistedDraft() { clearedPersistedCount += 1 }
    func persistDraft(_ text: String) { persistedDrafts.append(text) }
    func showError(_ message: String, haptic: ConversationSendHaptic?, operationID: UUID?) {
        errors.append((message, haptic, operationID))
    }
    func clearError() { clearedErrorCount += 1 }
    func emitHaptic(_ haptic: ConversationSendHaptic, operationID: UUID?) {
        haptics.append((haptic, operationID))
    }
    func beginHapticOperation() -> UUID {
        operationCount += 1
        return UUID()
    }
    func restoreImages(_ images: [StagedSendImage]) { restoredImageBatches.append(images) }
}
