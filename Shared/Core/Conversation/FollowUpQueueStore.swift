import Foundation
import Observation

struct FollowUpTarget: Hashable, Sendable {
    let hostID: String
    let sessionKey: String
}

struct FollowUpActivitySnapshot: Equatable, Sendable {
    let isWorking: Bool
    let hasPendingQuestion: Bool
    let isSending: Bool
    let isHostReady: Bool

    static let idleOffline = Self(
        isWorking: false,
        hasPendingQuestion: false,
        isSending: false,
        isHostReady: false
    )

    var shouldQueueNewFollowUp: Bool {
        isWorking || hasPendingQuestion || isSending
    }

    var canAutoFlushHead: Bool {
        isHostReady && !isWorking && !hasPendingQuestion && !isSending
    }

    static func resolve(
        session: SessionSummary?,
        store: ConversationStore?,
        isSending: Bool,
        isHostReady: Bool
    ) -> Self {
        let marker = session.map { SessionPresentation.activityMarker(for: $0) } ?? nil
        let pendingQuestion: Bool
        let working: Bool
        if let store {
            pendingQuestion = PendingQuestionGate.blocksInput(
                store.prompts,
                submission: store.questionSubmissionState
            ) || marker == .waiting || store.displayAttention == .waiting
            working = store.displayAttention == .working
                || marker == .working
                || store.hasRunningTool
                || !store.streamingDrafts.isEmpty
        } else {
            pendingQuestion = marker == .waiting || session?.attention == .waiting
            working = marker == .working || session?.attention == .working
        }
        return Self(
            isWorking: working,
            hasPendingQuestion: pendingQuestion,
            isSending: isSending,
            isHostReady: isHostReady
        )
    }
}

struct FollowUpItem: Identifiable, Equatable, Sendable {
    enum DeliveryState: Equatable, Sendable {
        case pending
        case sending
        case failed(String)
    }

    let id: UUID
    let text: String
    let images: [StagedSendImage]
    let files: [StagedSendFile]
    let createdAt: Date
    var state: DeliveryState = .pending

    var isSending: Bool { state == .sending }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var attachmentCount: Int { images.count + files.count }
}

struct SessionFollowUpQueue: Equatable, Sendable {
    var items: [FollowUpItem] = []
    var isPaused = false

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var hasSendingItem: Bool { items.contains { $0.isSending } }
    var hasFailedItem: Bool { items.contains { $0.failureMessage != nil } }
    var headFailureMessage: String? { items.first?.failureMessage }
}

enum FollowUpDispatchResult: Equatable, Sendable {
    case sent
    case deferred
    case failed(String)
}

@Observable
@MainActor
final class FollowUpQueueStore {
    typealias MountedDispatchHandler = @MainActor (FollowUpItem) async -> FollowUpDispatchResult
    typealias BackgroundDispatchHandler = @MainActor (FollowUpTarget, FollowUpItem) async -> FollowUpDispatchResult

    private struct MountedDispatcher {
        let token: UUID
        let handler: MountedDispatchHandler
    }

    private(set) var queues: [FollowUpTarget: SessionFollowUpQueue] = [:]

    @ObservationIgnored let idleSettleDuration: Duration
    @ObservationIgnored let postDispatchHoldDuration: Duration
    @ObservationIgnored var backgroundDispatcher: BackgroundDispatchHandler?

    @ObservationIgnored private var snapshots: [FollowUpTarget: FollowUpActivitySnapshot] = [:]
    @ObservationIgnored private var settleTasks: [FollowUpTarget: Task<Void, Never>] = [:]
    @ObservationIgnored private var postDispatchHoldUntil: [FollowUpTarget: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var mountedDispatchers: [FollowUpTarget: MountedDispatcher] = [:]
    #if DEBUG
    @ObservationIgnored private var inspectionSuppressAutoFlush = false
    #endif

    init(
        idleSettleDuration: Duration = .milliseconds(750),
        postDispatchHoldDuration: Duration = .seconds(3)
    ) {
        self.idleSettleDuration = idleSettleDuration
        self.postDispatchHoldDuration = postDispatchHoldDuration
    }

    func queue(forHostID hostID: String, sessionKey: String) -> SessionFollowUpQueue {
        queues[FollowUpTarget(hostID: hostID, sessionKey: sessionKey)] ?? SessionFollowUpQueue()
    }

    func shouldQueueFollowUp(
        hostID: String,
        sessionKey: String,
        snapshot: FollowUpActivitySnapshot
    ) -> Bool {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        snapshots[target] = snapshot
        return snapshot.shouldQueueNewFollowUp || !(queues[target]?.isEmpty ?? true)
    }

    @discardableResult
    func enqueue(
        hostID: String,
        sessionKey: String,
        text: String,
        images: [StagedSendImage],
        files: [StagedSendFile],
        createdAt: Date = Date()
    ) -> FollowUpItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty || !files.isEmpty else { return nil }
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        let item = FollowUpItem(
            id: UUID(),
            text: trimmed,
            images: images,
            files: files,
            createdAt: createdAt
        )
        queues[target, default: SessionFollowUpQueue()].items.append(item)
        scheduleEvaluationIfNeeded(for: target)
        return item
    }

    #if DEBUG
    func replaceQueueForInspection(
        hostID: String,
        sessionKey: String,
        items: [FollowUpItem],
        isPaused: Bool = false
    ) {
        inspectionSuppressAutoFlush = !items.isEmpty
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        settleTasks[target]?.cancel()
        settleTasks[target] = nil
        postDispatchHoldUntil[target] = nil
        if items.isEmpty {
            queues[target] = nil
        } else {
            queues[target] = SessionFollowUpQueue(items: items, isPaused: isPaused)
        }
    }
    #endif

    func updateSnapshot(
        _ snapshot: FollowUpActivitySnapshot,
        hostID: String,
        sessionKey: String
    ) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        if snapshot.isWorking {
            postDispatchHoldUntil[target] = nil
        }
        snapshots[target] = snapshot
        scheduleEvaluationIfNeeded(for: target)
    }

    /// Refreshes queued sessions that are not currently owned by a live detail view.
    func syncUnmountedSessions(
        _ sessions: [SessionSummary],
        hostID: String,
        isHostReady: Bool
    ) {
        let targetKeys = queues.keys.filter { $0.hostID == hostID }
        guard !targetKeys.isEmpty else { return }
        let byKey = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for target in targetKeys {
            guard mountedDispatchers[target] == nil else { continue }
            if let summary = byKey[target.sessionKey] {
                let snapshot = FollowUpActivitySnapshot.resolve(
                    session: summary,
                    store: nil,
                    isSending: false,
                    isHostReady: isHostReady
                )
                updateSnapshot(snapshot, hostID: hostID, sessionKey: target.sessionKey)
            } else if !isHostReady, let previous = snapshots[target] {
                updateSnapshot(
                    FollowUpActivitySnapshot(
                        isWorking: previous.isWorking,
                        hasPendingQuestion: previous.hasPendingQuestion,
                        isSending: previous.isSending,
                        isHostReady: false
                    ),
                    hostID: hostID,
                    sessionKey: target.sessionKey
                )
            }
        }
    }

    func pause(hostID: String, sessionKey: String) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard queues[target] != nil else { return }
        queues[target]?.isPaused = true
        settleTasks[target]?.cancel()
        settleTasks[target] = nil
    }

    func pauseIfActive(hostID: String, sessionKey: String) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard let queue = queues[target], !queue.isEmpty else { return }
        pause(hostID: hostID, sessionKey: sessionKey)
    }

    func resume(hostID: String, sessionKey: String) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard queues[target] != nil else { return }
        queues[target]?.isPaused = false
        if queues[target]?.items.first?.failureMessage != nil {
            queues[target]?.items[0].state = .pending
        }
        postDispatchHoldUntil[target] = nil
        scheduleEvaluationIfNeeded(for: target)
    }

    func sendNow(id: UUID, hostID: String, sessionKey: String) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard var queue = queues[target],
              let index = queue.items.firstIndex(where: { $0.id == id }),
              !queue.hasSendingItem else { return }
        if index > 0 {
            let item = queue.items.remove(at: index)
            queue.items.insert(item, at: 0)
        }
        queue.items[0].state = .pending
        queue.isPaused = false
        queues[target] = queue
        settleTasks[target]?.cancel()
        settleTasks[target] = nil
        postDispatchHoldUntil[target] = nil
        Task { @MainActor [weak self] in
            await self?.flushHeadIfReady(for: target, manual: true)
        }
    }

    @discardableResult
    func remove(id: UUID, hostID: String, sessionKey: String) -> FollowUpItem? {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard var queue = queues[target],
              let index = queue.items.firstIndex(where: { $0.id == id }),
              !queue.items[index].isSending else { return nil }
        let removed = queue.items.remove(at: index)
        storeOrRemoveQueue(queue, for: target)
        return removed
    }

    func popLastEditable(hostID: String, sessionKey: String) -> FollowUpItem? {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard var queue = queues[target],
              let index = queue.items.lastIndex(where: { !$0.isSending }) else { return nil }
        let popped = queue.items.remove(at: index)
        storeOrRemoveQueue(queue, for: target)
        return popped
    }

    func clear(hostID: String, sessionKey: String) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard var queue = queues[target] else { return }
        queue.items.removeAll { !$0.isSending }
        storeOrRemoveQueue(queue, for: target)
    }

    func registerMountedDispatcher(
        token: UUID,
        hostID: String,
        sessionKey: String,
        handler: @escaping MountedDispatchHandler
    ) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        mountedDispatchers[target] = MountedDispatcher(token: token, handler: handler)
        scheduleEvaluationIfNeeded(for: target)
    }

    func unregisterMountedDispatcher(
        token: UUID,
        hostID: String,
        sessionKey: String
    ) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        guard mountedDispatchers[target]?.token == token else { return }
        mountedDispatchers[target] = nil
    }

    func migrate(hostID: String, from oldKey: String, to newKey: String) {
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey else { return }
        let oldTarget = FollowUpTarget(hostID: hostID, sessionKey: oldKey)
        let newTarget = FollowUpTarget(hostID: hostID, sessionKey: newKey)
        settleTasks[oldTarget]?.cancel()
        settleTasks[oldTarget] = nil

        if let oldQueue = queues.removeValue(forKey: oldTarget) {
            if var existing = queues[newTarget] {
                existing.items.append(contentsOf: oldQueue.items)
                existing.isPaused = existing.isPaused && oldQueue.isPaused
                queues[newTarget] = existing
            } else {
                queues[newTarget] = oldQueue
            }
        }
        if let oldSnapshot = snapshots.removeValue(forKey: oldTarget), snapshots[newTarget] == nil {
            snapshots[newTarget] = oldSnapshot
        }
        if let oldHold = postDispatchHoldUntil.removeValue(forKey: oldTarget) {
            if let currentHold = postDispatchHoldUntil[newTarget] {
                postDispatchHoldUntil[newTarget] = max(oldHold, currentHold)
            } else {
                postDispatchHoldUntil[newTarget] = oldHold
            }
        }
        if let oldMounted = mountedDispatchers.removeValue(forKey: oldTarget),
           mountedDispatchers[newTarget] == nil {
            mountedDispatchers[newTarget] = oldMounted
        }
        scheduleEvaluationIfNeeded(for: newTarget)
    }

    func clearSession(hostID: String, sessionKey: String) {
        let target = FollowUpTarget(hostID: hostID, sessionKey: sessionKey)
        settleTasks[target]?.cancel()
        settleTasks[target] = nil
        postDispatchHoldUntil[target] = nil
        snapshots[target] = nil
        mountedDispatchers[target] = nil
        queues[target] = nil
    }

    func clearHost(hostID: String) {
        let targets = Set(queues.keys)
            .union(snapshots.keys)
            .union(settleTasks.keys)
            .union(postDispatchHoldUntil.keys)
            .union(mountedDispatchers.keys)
            .filter { $0.hostID == hostID }
        for target in targets {
            clearSession(hostID: target.hostID, sessionKey: target.sessionKey)
        }
    }

    // MARK: - Scheduling & dispatch

    private func storeOrRemoveQueue(_ queue: SessionFollowUpQueue, for target: FollowUpTarget) {
        if queue.isEmpty {
            settleTasks[target]?.cancel()
            settleTasks[target] = nil
            postDispatchHoldUntil[target] = nil
            queues[target] = nil
        } else {
            queues[target] = queue
            scheduleEvaluationIfNeeded(for: target)
        }
    }

    private func scheduleEvaluationIfNeeded(for target: FollowUpTarget) {
        #if DEBUG
        guard !inspectionSuppressAutoFlush else { return }
        #endif
        guard let queue = queues[target],
              !queue.isEmpty,
              !queue.isPaused,
              !queue.hasSendingItem,
              queue.headFailureMessage == nil,
              let snapshot = snapshots[target],
              snapshot.canAutoFlushHead else {
            settleTasks[target]?.cancel()
            settleTasks[target] = nil
            return
        }
        if settleTasks[target] != nil {
            return
        }
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: idleSettleDuration)
        if let holdUntil = postDispatchHoldUntil[target], holdUntil > deadline {
            deadline = holdUntil
        }
        settleTasks[target] = Task { @MainActor [weak self] in
            let delay = clock.now.duration(to: deadline)
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.settleTasks[target] = nil
            await self.flushHeadIfReady(for: target, manual: false)
        }
    }

    private func flushHeadIfReady(for target: FollowUpTarget, manual: Bool) async {
        #if DEBUG
        guard !inspectionSuppressAutoFlush else { return }
        #endif
        guard var queue = queues[target],
              let head = queue.items.first,
              !queue.hasSendingItem else { return }
        if !manual {
            guard !queue.isPaused,
                  head.failureMessage == nil,
                  snapshots[target]?.canAutoFlushHead == true else { return }
            if let holdUntil = postDispatchHoldUntil[target], ContinuousClock.now < holdUntil {
                scheduleEvaluationIfNeeded(for: target)
                return
            }
        }
        queue.items[0].state = .sending
        queue.isPaused = false
        queues[target] = queue

        let result: FollowUpDispatchResult
        if let mounted = mountedDispatchers[target] {
            result = await mounted.handler(head)
        } else if let backgroundDispatcher {
            result = await backgroundDispatcher(target, head)
        } else {
            result = .deferred
        }

        guard let location = locateItem(id: head.id, preferredTarget: target) else { return }
        let currentTarget = location.target
        var latestQueue = queues[currentTarget] ?? SessionFollowUpQueue()
        let itemIndex = location.index

        switch result {
        case .sent:
            latestQueue.items.remove(at: itemIndex)
            if !latestQueue.isEmpty {
                postDispatchHoldUntil[currentTarget] = ContinuousClock.now.advanced(by: postDispatchHoldDuration)
            }
            storeOrRemoveQueue(latestQueue, for: currentTarget)
        case .deferred:
            latestQueue.items[itemIndex].state = .pending
            queues[currentTarget] = latestQueue
            scheduleEvaluationIfNeeded(for: currentTarget)
        case .failed(let message):
            latestQueue.items[itemIndex].state = .failed(message)
            latestQueue.isPaused = true
            queues[currentTarget] = latestQueue
            settleTasks[currentTarget]?.cancel()
            settleTasks[currentTarget] = nil
        }
    }

    private func locateItem(
        id: UUID,
        preferredTarget: FollowUpTarget
    ) -> (target: FollowUpTarget, index: Int)? {
        if let index = queues[preferredTarget]?.items.firstIndex(where: { $0.id == id }) {
            return (preferredTarget, index)
        }
        for (candidateTarget, queue) in queues where candidateTarget.hostID == preferredTarget.hostID {
            if let index = queue.items.firstIndex(where: { $0.id == id }) {
                return (candidateTarget, index)
            }
        }
        return nil
    }
}
