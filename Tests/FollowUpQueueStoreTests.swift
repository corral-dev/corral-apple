import XCTest
@testable import Corral

@MainActor
final class FollowUpQueueStoreTests: XCTestCase {
    private let hostID = "host-1"
    private let sessionKey = "codex:session-1"

    func testShouldQueueFollowUpTracksBusyWaitingSendingAndExistingQueue() {
        let store = FollowUpQueueStore(
            idleSettleDuration: .milliseconds(25),
            postDispatchHoldDuration: .milliseconds(60)
        )
        let idle = FollowUpActivitySnapshot(
            isWorking: false,
            hasPendingQuestion: false,
            isSending: false,
            isHostReady: true
        )
        XCTAssertFalse(store.shouldQueueFollowUp(hostID: hostID, sessionKey: sessionKey, snapshot: idle))

        let working = FollowUpActivitySnapshot(
            isWorking: true,
            hasPendingQuestion: false,
            isSending: false,
            isHostReady: true
        )
        XCTAssertTrue(store.shouldQueueFollowUp(hostID: hostID, sessionKey: sessionKey, snapshot: working))

        let waiting = FollowUpActivitySnapshot(
            isWorking: false,
            hasPendingQuestion: true,
            isSending: false,
            isHostReady: true
        )
        XCTAssertTrue(store.shouldQueueFollowUp(hostID: hostID, sessionKey: sessionKey, snapshot: waiting))

        let sending = FollowUpActivitySnapshot(
            isWorking: false,
            hasPendingQuestion: false,
            isSending: true,
            isHostReady: true
        )
        XCTAssertTrue(store.shouldQueueFollowUp(hostID: hostID, sessionKey: sessionKey, snapshot: sending))

        _ = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "queued 1", images: [], files: [])
        XCTAssertTrue(store.shouldQueueFollowUp(hostID: hostID, sessionKey: sessionKey, snapshot: idle))
    }

    func testActivitySnapshotResolveIgnoresRecentMarkerAloneAndCountsWorkingOrTool() throws {
        let recentSummary = SessionSummary(
            key: sessionKey,
            runtime: "codex",
            title: "Recent",
            cwd: "/tmp",
            live: true,
            attention: .unread,
            marker: "recent"
        )
        let recentSnapshot = FollowUpActivitySnapshot.resolve(
            session: recentSummary,
            store: nil,
            isSending: false,
            isHostReady: true
        )
        XCTAssertFalse(recentSnapshot.isWorking)
        XCTAssertFalse(recentSnapshot.hasPendingQuestion)
        XCTAssertTrue(recentSnapshot.canAutoFlushHead)

        let workingSummary = SessionSummary(
            key: sessionKey,
            runtime: "codex",
            title: "Working",
            cwd: "/tmp",
            live: true,
            attention: .working,
            marker: "working"
        )
        let workingSnapshot = FollowUpActivitySnapshot.resolve(
            session: workingSummary,
            store: nil,
            isSending: false,
            isHostReady: true
        )
        XCTAssertTrue(workingSnapshot.isWorking)

        let waitingSummary = SessionSummary(
            key: sessionKey,
            runtime: "codex",
            title: "Waiting",
            cwd: "/tmp",
            live: true,
            attention: .waiting,
            marker: "waiting"
        )
        let waitingSnapshot = FollowUpActivitySnapshot.resolve(
            session: waitingSummary,
            store: nil,
            isSending: false,
            isHostReady: true
        )
        XCTAssertTrue(waitingSnapshot.hasPendingQuestion)

        let conv = ConversationStore(sessionKey: sessionKey, client: nil, live: true, attention: .none)
        let snapshot = try RemoteJSONDecoder.decode(
            SessionMessagesResponse.self,
            from: [
                "messages": [[
                    "seq": 1,
                    "role": "assistant",
                    "tools": [[
                        "name": "shell",
                        "status": "running",
                    ]],
                ]],
                "generation": 1,
                "oldest_seq": 1,
                "newest_seq": 1,
                "has_more": false,
            ]
        )
        conv.applySnapshot(snapshot)
        let convSnapshot = FollowUpActivitySnapshot.resolve(
            session: recentSummary,
            store: conv,
            isSending: false,
            isHostReady: true
        )
        XCTAssertTrue(convSnapshot.isWorking)
    }

    func testAutoFlushWaitsForSettleThenHoldInFifoOrder() async {
        let store = FollowUpQueueStore(
            idleSettleDuration: .milliseconds(30),
            postDispatchHoldDuration: .milliseconds(120)
        )
        var dispatched: [String] = []
        let token = UUID()
        store.registerMountedDispatcher(token: token, hostID: hostID, sessionKey: sessionKey) { item in
            dispatched.append(item.text)
            return .sent
        }

        store.updateSnapshot(
            FollowUpActivitySnapshot(isWorking: true, hasPendingQuestion: false, isSending: false, isHostReady: true),
            hostID: hostID,
            sessionKey: sessionKey
        )
        _ = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "first", images: [], files: [])
        _ = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "second", images: [], files: [])

        // Resuming work before idle settle completes cancels premature flush.
        store.updateSnapshot(
            FollowUpActivitySnapshot(isWorking: false, hasPendingQuestion: false, isSending: false, isHostReady: true),
            hostID: hostID,
            sessionKey: sessionKey
        )
        try? await Task.sleep(for: .milliseconds(10))
        store.updateSnapshot(
            FollowUpActivitySnapshot(isWorking: true, hasPendingQuestion: false, isSending: false, isHostReady: true),
            hostID: hostID,
            sessionKey: sessionKey
        )
        try? await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(dispatched.isEmpty)

        // Becoming idle settles and sends "first", then holds before "second".
        store.updateSnapshot(
            FollowUpActivitySnapshot(isWorking: false, hasPendingQuestion: false, isSending: false, isHostReady: true),
            hostID: hostID,
            sessionKey: sessionKey
        )
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(dispatched, ["first"])
        XCTAssertEqual(store.queue(forHostID: hostID, sessionKey: sessionKey).items.map(\.text), ["second"])

        // Hold expires and sends "second".
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(dispatched, ["first", "second"])
        XCTAssertTrue(store.queue(forHostID: hostID, sessionKey: sessionKey).isEmpty)
    }

    func testPostDispatchHoldClearsEarlyWhenWorkingResumes() async {
        let store = FollowUpQueueStore(
            idleSettleDuration: .milliseconds(25),
            postDispatchHoldDuration: .seconds(5)
        )
        var dispatched: [String] = []
        let token = UUID()
        store.registerMountedDispatcher(token: token, hostID: hostID, sessionKey: sessionKey) { item in
            dispatched.append(item.text)
            return .sent
        }

        let idle = FollowUpActivitySnapshot(isWorking: false, hasPendingQuestion: false, isSending: false, isHostReady: true)
        let working = FollowUpActivitySnapshot(isWorking: true, hasPendingQuestion: false, isSending: false, isHostReady: true)
        store.updateSnapshot(idle, hostID: hostID, sessionKey: sessionKey)
        _ = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "one", images: [], files: [])
        _ = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "two", images: [], files: [])

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(dispatched, ["one"])

        // Host echoes working -> ends 5s hold early -> returns idle -> sends "two".
        store.updateSnapshot(working, hostID: hostID, sessionKey: sessionKey)
        store.updateSnapshot(idle, hostID: hostID, sessionKey: sessionKey)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(dispatched, ["one", "two"])
    }

    func testPauseResumeStopFailureAndSendNow() async {
        @MainActor
        final class DispatchRecorder {
            var shouldFail = true
            var dispatched: [String] = []
        }

        let store = FollowUpQueueStore(
            idleSettleDuration: .milliseconds(20),
            postDispatchHoldDuration: .milliseconds(20)
        )
        let recorder = DispatchRecorder()
        let token = UUID()
        store.registerMountedDispatcher(token: token, hostID: hostID, sessionKey: sessionKey) { item in
            if recorder.shouldFail {
                return .failed("Network unavailable")
            }
            recorder.dispatched.append(item.text)
            return .sent
        }

        store.updateSnapshot(
            FollowUpActivitySnapshot(isWorking: true, hasPendingQuestion: false, isSending: false, isHostReady: true),
            hostID: hostID,
            sessionKey: sessionKey
        )
        let first = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "alpha", images: [], files: [])!
        let second = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "beta", images: [], files: [])!

        // Stop pauses the active queue.
        store.pauseIfActive(hostID: hostID, sessionKey: sessionKey)
        XCTAssertTrue(store.queue(forHostID: hostID, sessionKey: sessionKey).isPaused)
        store.updateSnapshot(
            FollowUpActivitySnapshot(isWorking: false, hasPendingQuestion: false, isSending: false, isHostReady: true),
            hostID: hostID,
            sessionKey: sessionKey
        )
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(recorder.dispatched.isEmpty)

        // Resume attempts dispatch -> fails and pauses queue on head.
        store.resume(hostID: hostID, sessionKey: sessionKey)
        try? await Task.sleep(for: .milliseconds(80))
        let afterFail = store.queue(forHostID: hostID, sessionKey: sessionKey)
        XCTAssertTrue(afterFail.isPaused)
        XCTAssertEqual(afterFail.items.first?.id, first.id)
        XCTAssertEqual(afterFail.headFailureMessage, "Network unavailable")

        // Send now on second item promotes it to head and sends it; failed item stays failed until explicitly retried.
        recorder.shouldFail = false
        store.sendNow(id: second.id, hostID: hostID, sessionKey: sessionKey)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(recorder.dispatched, ["beta"])
        XCTAssertEqual(store.queue(forHostID: hostID, sessionKey: sessionKey).items.map(\.id), [first.id])
        XCTAssertEqual(store.queue(forHostID: hostID, sessionKey: sessionKey).headFailureMessage, "Network unavailable")

        // Retrying the failed item via Send now clears it and empties the queue.
        store.sendNow(id: first.id, hostID: hostID, sessionKey: sessionKey)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(recorder.dispatched, ["beta", "alpha"])
        XCTAssertTrue(store.queue(forHostID: hostID, sessionKey: sessionKey).isEmpty)
    }

    func testRecallEditRemoveClearMigrateTokenGuardAndDisconnect() async {
        let store = FollowUpQueueStore(
            idleSettleDuration: .milliseconds(20),
            postDispatchHoldDuration: .milliseconds(20)
        )
        var backgroundCalls: [String] = []
        store.backgroundDispatcher = { target, item in
            backgroundCalls.append("\(target.sessionKey):\(item.text)")
            return .sent
        }

        let oldToken = UUID()
        let newToken = UUID()
        store.registerMountedDispatcher(token: oldToken, hostID: hostID, sessionKey: sessionKey) { _ in .deferred }
        store.registerMountedDispatcher(token: newToken, hostID: hostID, sessionKey: sessionKey) { _ in .deferred }
        // Stale unregister must NOT remove the newer dispatcher.
        store.unregisterMountedDispatcher(token: oldToken, hostID: hostID, sessionKey: sessionKey)

        _ = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "item-1", images: [], files: [])
        _ = store.enqueue(hostID: hostID, sessionKey: sessionKey, text: "item-2", images: [], files: [])
        let recalled = store.popLastEditable(hostID: hostID, sessionKey: sessionKey)
        XCTAssertEqual(recalled?.text, "item-2")
        XCTAssertEqual(store.queue(forHostID: hostID, sessionKey: sessionKey).count, 1)

        // Unregistering newer token falls back to backgroundDispatcher when ready.
        store.unregisterMountedDispatcher(token: newToken, hostID: hostID, sessionKey: sessionKey)

        // Disconnected stays queued until ready; migrating moves queue cleanly.
        let migratedKey = "codex:session-real"
        store.migrate(hostID: hostID, from: sessionKey, to: migratedKey)
        XCTAssertTrue(store.queue(forHostID: hostID, sessionKey: sessionKey).isEmpty)
        XCTAssertEqual(store.queue(forHostID: hostID, sessionKey: migratedKey).items.map(\.text), ["item-1"])

        store.updateSnapshot(.idleOffline, hostID: hostID, sessionKey: migratedKey)
        try? await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(backgroundCalls.isEmpty)

        store.updateSnapshot(
            FollowUpActivitySnapshot(isWorking: false, hasPendingQuestion: false, isSending: false, isHostReady: true),
            hostID: hostID,
            sessionKey: migratedKey
        )
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(backgroundCalls, ["\(migratedKey):item-1"])

        // clearHost cleans up remaining state.
        _ = store.enqueue(hostID: hostID, sessionKey: migratedKey, text: "item-3", images: [], files: [])
        store.clearHost(hostID: hostID)
        XCTAssertTrue(store.queue(forHostID: hostID, sessionKey: migratedKey).isEmpty)
    }
}
