import Foundation
@testable import Corral
import XCTest

@MainActor
final class SessionListStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-list-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        SessionListCache.directoryOverride = scratch
    }

    override func tearDown() async throws {
        SessionListCache.flushPendingWrites()
        SessionListCache.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testCalendarRefreshesUnchangedOfflineAndReopenedSnapshots() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 59))!
        let activity = now.timeIntervalSince1970
        let store = SessionListStore(now: { now }, calendar: { calendar })
        store.loadPersisted(hostID: "calendar-host")
        let row = SessionSummary(key: "codex:last-night", runtime: "codex", title: "Last night", cwd: "/p", mtime: activity, live: true)
        store.updateSessions([row])
        XCTAssertEqual(store.sections.map(\.id), ["today"])
        now = now.addingTimeInterval(120)
        store.applyListResponse(SessionsListResponse(sessions: [], version: store.version, unchanged: true))
        XCTAssertEqual(store.sections.map(\.id), ["yesterday"])
        XCTAssertEqual(store.windowSessions, [row])
        store.searchQuery = "Last"
        now = now.addingTimeInterval(86400)
        store.refreshCalendar()
        XCTAssertEqual(store.sections.map(\.id), ["earlier"])
        XCTAssertEqual(store.searchQuery, "Last")
        // Reopening the same host must not keep yesterday's projection.
        now = now.addingTimeInterval(-86400)
        store.loadPersisted(hostID: "calendar-host")
        XCTAssertEqual(store.sections.map(\.id), ["yesterday"])
    }

    func testCalendarUsesNewTimeZoneAndDSTDayLength() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 1))!
        let row = SessionSummary(key: "claude:dst", runtime: "claude", title: "DST", cwd: "/p", mtime: now.timeIntervalSince1970, live: false)
        let store = SessionListStore(now: { now }, calendar: { calendar })
        store.updateSessions([row])
        XCTAssertEqual(store.sections.map(\.id), ["today"])
        now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 1))!
        store.refreshCalendar()
        XCTAssertEqual(store.sections.map(\.id), ["yesterday"])
        now = Date(timeIntervalSince1970: row.mtime + 3600)
        calendar.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        store.refreshCalendar()
        XCTAssertEqual(store.presentationCalendar.timeZone.identifier, "Pacific/Honolulu")
        XCTAssertEqual(store.sections.map(\.id), ["today"])
    }

    func testConfirmedDeleteRejectsDelayedListSearchAndDetailAcrossReconnect() throws {
        let store = SessionListStore()
        store.loadPersisted(hostID: "delete-host")
        let deleted = try session(key: "claude:deleted", title: "Deleted")
        let kept = try session(key: "claude:kept", title: "Kept")
        store.updateSessions([deleted, kept])
        store.rememberOpened(deleted)
        store.removeSession(key: deleted.key)
        store.beginConnectionEpoch()
        store.applyListResponse(SessionsListResponse(sessions: [deleted, kept], version: "stale", revision: 99))
        store.applySessionEvent(deleted, revision: 100)
        store.searchQuery = "Deleted"
        store.applySearchHits([deleted], query: "Deleted")
        XCTAssertNil(store.session(for: deleted.key))
        XCTAssertTrue(store.filteredSessions.isEmpty)
        store.searchQuery = ""
        XCTAssertEqual(store.windowSessions.map(\.key), [kept.key])
        SessionListCache.flushPendingWrites()
        XCTAssertEqual(SessionListCache.load(hostID: "delete-host")?.sessions.map(\.key), [kept.key])
    }

    func testConfirmedDeleteFollowsLateIdentityMigrationAndExistingAliases() throws {
        let store = SessionListStore()
        let provisional = try session(key: "claude:provisional", title: "Provisional")
        let canonical = try session(key: "claude:canonical", title: "Canonical")
        store.updateSessions([provisional])
        store.removeSession(key: provisional.key)
        store.migrateSession(from: provisional.key, to: canonical.key)
        store.updateSessions([provisional, canonical])
        XCTAssertTrue(store.windowSessions.isEmpty)
        XCTAssertNil(store.session(for: canonical.key))

        let second = SessionListStore()
        second.updateSessions([provisional])
        second.migrateSession(from: provisional.key, to: canonical.key)
        second.removeSession(key: provisional.key)
        second.patchSession(canonical)
        second.patchSession(provisional)
        XCTAssertTrue(second.windowSessions.isEmpty)
    }

    func testDeletedIdentityIsScopedToItsHost() throws {
        let store = SessionListStore()
        let row = try session(key: "claude:same-key", title: "Session")
        store.loadPersisted(hostID: "host-a")
        store.updateSessions([row])
        store.removeSession(key: row.key)
        store.loadPersisted(hostID: "host-b")
        store.updateSessions([row])
        XCTAssertEqual(store.session(for: row.key)?.title, row.title)
    }

    func testReplacedSearchAndWindowReleaseUnownedMetadata() throws {
        let store = SessionListStore()
        let opened = try session(key: "claude:opened", title: "Opened")
        store.updateSessions([opened])
        store.rememberOpened(opened)
        store.updateSessions([try session(key: "claude:window", title: "Window")])
        for index in 0..<200 {
            let row = try session(key: "claude:hit-\(index)", title: "Hit")
            store.searchQuery = "Hit"
            store.applySearchHits([row], query: "Hit")
            if index > 0 { XCTAssertNil(store.session(for: "claude:hit-\(index - 1)")) }
        }
        XCTAssertNotNil(store.session(for: opened.key))
        XCTAssertNotNil(store.session(for: "claude:window"))
        store.searchQuery = ""
        XCTAssertNil(store.session(for: "claude:hit-199"))
        store.forgetOpened(key: opened.key)
        XCTAssertNil(store.session(for: opened.key))
        XCTAssertNotNil(store.session(for: "claude:window"))
    }

    func testCacheCoalescesLatestSnapshotAndUnpairCancelsQueuedWrite() throws {
        let first = SessionListSnapshot(version: "1", sessions: [try session(key: "claude:a", title: "Old")])
        let latest = SessionListSnapshot(version: "2", sessions: [try session(key: "claude:a", title: "New")])
        SessionListCache.save(hostID: "host-a", snapshot: first)
        SessionListCache.save(hostID: "host-a", snapshot: latest)
        XCTAssertEqual(SessionListCache.load(hostID: "host-a"), latest)
        SessionListCache.flushPendingWrites()
        let url = try XCTUnwrap(SessionListCache.fileURL(hostID: "host-a"))
        XCTAssertEqual(try JSONDecoder().decode(SessionListSnapshot.self, from: Data(contentsOf: url)), latest)
        SessionListCache.save(hostID: "host-a", snapshot: first)
        SessionListCache.removeAll(hostID: "host-a")
        SessionListCache.flushPendingWrites()
        XCTAssertNil(SessionListCache.load(hostID: "host-a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewConnectionAcceptsResetHostRevisionWithoutBlankingRows() throws {
        let store = SessionListStore()
        store.applyListResponse(SessionsListResponse(
            sessions: [try session(key: "claude:a", title: "Before restart")],
            version: "old", revision: 100), persist: false)
        store.beginConnectionEpoch()
        XCTAssertEqual(store.session(for: "claude:a")?.title, "Before restart")
        XCTAssertEqual(store.version, "")
        store.applyListResponse(SessionsListResponse(
            sessions: [try session(key: "claude:a", title: "After restart")],
            version: "new", revision: 1), persist: false)
        XCTAssertEqual(store.session(for: "claude:a")?.title, "After restart")
        store.applySessionEvent(try session(key: "claude:a", title: "Late old snapshot"), revision: 0)
        XCTAssertEqual(store.session(for: "claude:a")?.title, "After restart")
    }

    func testReturnToSameHostDoesNotReloadOlderDiskSnapshot() throws {
        let store = SessionListStore()
        store.loadPersisted(hostID: "host-a")
        store.applyListResponse(SessionsListResponse(
            sessions: [try session(key: "claude:a", title: "Disk")], version: "old"))
        store.applyListResponse(SessionsListResponse(
            sessions: [try session(key: "claude:a", title: "Live")], version: "new"), persist: false)
        store.loadPersisted(hostID: "host-a")
        XCTAssertEqual(store.session(for: "claude:a")?.title, "Live")
        XCTAssertEqual(store.version, "new")
    }

    func testUnchangedResponseDoesNotWipeExistingRows() throws {
        let store = SessionListStore()
        store.updateSessions([try session(key: "claude:keep", title: "还在")])
        XCTAssertEqual(store.sections.flatMap(\.sessions).map(\.key), ["claude:keep"])

        store.applyListResponse(
            SessionsListResponse(sessions: [], version: "abc", unchanged: true),
            persist: false
        )
        XCTAssertEqual(store.sections.flatMap(\.sessions).map(\.key), ["claude:keep"])
        XCTAssertEqual(store.version, "abc")
    }

    func testPersistedSnapshotPaintsBeforeNetwork() throws {
        let first = SessionListStore()
        first.loadPersisted(hostID: "host-a")
        first.applyListResponse(
            SessionsListResponse(
                sessions: [try session(key: "codex:one", title: "上次的会话")],
                version: "v1"
            )
        )

        let second = SessionListStore()
        second.loadPersisted(hostID: "host-a")
        XCTAssertEqual(second.version, "v1")
        XCTAssertEqual(second.sections.flatMap(\.sessions).map(\.title), ["上次的会话"])
    }

    func testDifferentHostDoesNotReuseSnapshot() throws {
        let store = SessionListStore()
        store.loadPersisted(hostID: "host-a")
        store.applyListResponse(
            SessionsListResponse(sessions: [try session(key: "claude:a", title: "A机")], version: "a")
        )

        let other = SessionListStore()
        other.loadPersisted(hostID: "host-b")
        XCTAssertTrue(other.sections.isEmpty)
    }

    func testRemoveAllClearsPersistedSnapshot() throws {
        let store = SessionListStore()
        store.loadPersisted(hostID: "host-a")
        store.applyListResponse(
            SessionsListResponse(sessions: [try session(key: "claude:a", title: "旧列表")], version: "v1")
        )
        XCTAssertNotNil(SessionListCache.load(hostID: "host-a"))

        SessionListCache.removeAll(hostID: "host-a")
        XCTAssertNil(SessionListCache.load(hostID: "host-a"))

        let again = SessionListStore()
        again.loadPersisted(hostID: "host-a")
        XCTAssertTrue(again.sections.isEmpty)
    }

    func testDecodeUnchangedOmitsSessionArray() throws {
        let response = try RemoteJSONDecoder.decode(
            SessionsListResponse.self,
            from: ["version": "v9", "unchanged": true, "has_more": true, "total": 500]
        )
        XCTAssertTrue(response.unchanged)
        XCTAssertEqual(response.version, "v9")
        XCTAssertEqual(response.sessions, [])
        XCTAssertEqual(response.hasMore, true)
        XCTAssertEqual(response.total, 500)
    }

    func testTitleOnlyMergeUpdatesSharedRecord() throws {
        let store = SessionListStore()
        store.applyListResponse(
            SessionsListResponse(
                sessions: [try session(key: "claude:a", title: "fallback")],
                version: "v1",
                revision: 1
            ),
            persist: false
        )

        store.applySessionEvent(
            try session(key: "claude:a", title: "Generated title"),
            revision: 2
        )

        XCTAssertEqual(store.session(for: "claude:a")?.title, "Generated title")
        XCTAssertEqual(store.sections.flatMap(\.sessions).map(\.title), ["Generated title"])
    }

    func testEmptyTitleDoesNotWipePrior() throws {
        let store = SessionListStore()
        store.applyListResponse(
            SessionsListResponse(
                sessions: [try session(key: "claude:a", title: "Keep me")],
                version: "v1"
            ),
            persist: false
        )

        store.applySessionEvent(try session(key: "claude:a", title: ""), revision: 2)
        XCTAssertEqual(store.session(for: "claude:a")?.title, "Keep me")
    }

    func testStaleRevisionIsRejected() throws {
        let store = SessionListStore()
        store.applyListResponse(
            SessionsListResponse(
                sessions: [try session(key: "claude:a", title: "Fresh")],
                version: "v2",
                revision: 10
            ),
            persist: false
        )

        store.applySessionEvent(try session(key: "claude:a", title: "Stale"), revision: 9)
        XCTAssertEqual(store.session(for: "claude:a")?.title, "Fresh")

        store.applyListResponse(
            SessionsListResponse(
                sessions: [try session(key: "claude:a", title: "Older window")],
                version: "v1",
                revision: 8
            ),
            persist: false
        )
        XCTAssertEqual(store.session(for: "claude:a")?.title, "Fresh")
    }

    func testMigrateSessionKeepsProvisionalLookup() throws {
        let store = SessionListStore()
        let provisional = try session(key: "pi:tmp", title: "Draft")
        store.applyListResponse(
            SessionsListResponse(sessions: [provisional], version: "v1"),
            persist: false
        )
        store.rememberOpened(provisional)

        store.migrateSession(from: "pi:tmp", to: "pi:canonical")
        XCTAssertEqual(store.session(for: "pi:tmp")?.key, "pi:canonical")
        XCTAssertEqual(store.session(for: "pi:canonical")?.title, "Draft")
        XCTAssertEqual(store.sections.flatMap(\.sessions).map(\.key), ["pi:canonical"])

        store.applySessionEvent(
            try session(key: "pi:canonical", title: "Named"),
            revision: 3
        )
        XCTAssertEqual(store.session(for: "pi:tmp")?.title, "Named")
        XCTAssertEqual(store.session(for: "pi:canonical")?.title, "Named")
    }

    func testApplySessionEventUpdatesOpenedOutsideWindow() throws {
        let store = SessionListStore()
        store.applyListResponse(
            SessionsListResponse(
                sessions: [try session(key: "claude:visible", title: "Visible")],
                version: "v1",
                revision: 1
            ),
            persist: false
        )

        let hidden = try session(key: "claude:hidden", title: "Old title")
        store.rememberOpened(hidden)
        store.applySessionEvent(hidden, revision: 2)

        XCTAssertEqual(store.session(for: "claude:hidden")?.title, "Old title")
        XCTAssertFalse(store.sections.flatMap(\.sessions).map(\.key).contains("claude:hidden"))

        store.applySessionEvent(
            try session(key: "claude:hidden", title: "Host title"),
            revision: 3
        )
        XCTAssertEqual(store.session(for: "claude:hidden")?.title, "Host title")
        XCTAssertEqual(store.sections.flatMap(\.sessions).map(\.key), ["claude:visible"])
    }

    func testSessionPatchAcceptsSummaryOrSessionShapes() throws {
        let summaryShape: [String: Any] = [
            "kind": "metadata",
            "session": "claude:a",
            "revision": 4,
            "summary": sessionDict(key: "claude:a", title: "From summary"),
        ]
        let summaryPatch = try XCTUnwrap(SessionListStore.sessionPatch(from: summaryShape))
        XCTAssertEqual(summaryPatch.0.title, "From summary")
        XCTAssertEqual(summaryPatch.1, 4)

        let sessionShape: [String: Any] = [
            "revision": 5,
            "session": sessionDict(key: "claude:a", title: "From session object"),
        ]
        let sessionPatch = try XCTUnwrap(SessionListStore.sessionPatch(from: sessionShape))
        XCTAssertEqual(sessionPatch.0.title, "From session object")
        XCTAssertEqual(sessionPatch.1, 5)

        // String session key without summary/object must not crash or decode.
        let stringOnly: [String: Any] = [
            "kind": "metadata",
            "session": "claude:a",
            "revision": 6,
        ]
        XCTAssertNil(SessionListStore.sessionPatch(from: stringOnly))
    }

    func testMetadataEventForwardsIntoSharedStore() async throws {
        let store = SessionListStore()
        let seed = try session(key: "claude:a", title: "Before")
        store.applyListResponse(
            SessionsListResponse(sessions: [seed], version: "v1", revision: 1),
            persist: false
        )
        store.rememberOpened(seed)

        let conversation = ConversationStore(
            sessionKey: "claude:a",
            client: nil,
            live: false,
            attention: .none,
            hostID: "host-a"
        )
        conversation.onSessionMetadata = { summary, revision in
            store.applySessionEvent(summary, revision: revision)
        }

        await conversation.handle(
            RemoteEvent(
                channel: "session:claude:a",
                data: [
                    "kind": "metadata",
                    "session": "claude:a",
                    "revision": 7,
                    "summary": sessionDict(key: "claude:a", title: "Live title"),
                ]
            )
        )

        XCTAssertEqual(store.session(for: "claude:a")?.title, "Live title")
        XCTAssertGreaterThan(store.metadataEpoch, 0)
    }

    func testDormantRuntimeHiddenFromLiveListAndLookup() throws {
        let store = SessionListStore()
        store.updateSessions([
            try session(key: "kimi:kept-history", title: "旧 Kimi", runtime: "kimi"),
            try session(key: "claude:a", title: "A", runtime: "claude"),
            try session(key: "codex:b", title: "B", runtime: "codex"),
            try session(key: "opencode:c", title: "C", runtime: "opencode"),
            try session(key: "cursor:d", title: "D", runtime: "cursor"),
            try session(key: "pi:e", title: "E", runtime: "pi"),
            try session(key: "next:f", title: "F", runtime: "next-agent"),
            try session(key: "noruntime:g", title: "G"),
        ])
        let visible = store.sections.flatMap(\.sessions).map(\.key)
        XCTAssertFalse(visible.contains("kimi:kept-history"))
        for key in ["claude:a", "codex:b", "opencode:c", "cursor:d", "pi:e", "next:f", "noruntime:g"] {
            XCTAssertTrue(visible.contains(key), key)
            XCTAssertNotNil(store.session(for: key), key)
        }
        XCTAssertNil(store.session(for: "kimi:kept-history"))
    }

    func testLegacySnapshotSelfHealsOnLoad() throws {
        let first = SessionListStore()
        first.loadPersisted(hostID: "host-legacy")
        first.updateSessions([
            try session(key: "kimi:kept-history", title: "旧 Kimi", runtime: "kimi"),
            try session(key: "claude:active", title: "现行", runtime: "claude"),
        ])
        // Legacy snapshot on disk still carries the dormant row (host files untouched).
        SessionListCache.save(
            hostID: "host-legacy",
            snapshot: SessionListSnapshot(
                version: "legacy",
                sessions: [
                    try session(key: "kimi:kept-history", title: "旧 Kimi", runtime: "kimi"),
                    try session(key: "claude:active", title: "现行", runtime: "claude"),
                ]
            )
        )

        let second = SessionListStore()
        second.loadPersisted(hostID: "host-legacy")
        XCTAssertEqual(second.sections.flatMap(\.sessions).map(\.key), ["claude:active"])
        XCTAssertNil(second.session(for: "kimi:kept-history"))
        // Next persist rewrites the snapshot without the dormant row.
        second.removeSession(key: "claude:active")
        second.updateSessions([try session(key: "claude:active", title: "现行", runtime: "claude")])
        let rewritten = try XCTUnwrap(SessionListCache.load(hostID: "host-legacy"))
        XCTAssertFalse(rewritten.sessions.map(\.key).contains("kimi:kept-history"))
    }

    func testDormantSearchHitsEventsAndDirectPatchStayHidden() throws {
        let store = SessionListStore()
        store.updateSessions([try session(key: "claude:a", title: "A", runtime: "claude")])

        store.applySearchHits(
            [try session(key: "kimi:hit", title: "命中", runtime: "kimi")],
            query: "命中"
        )
        XCTAssertNil(store.session(for: "kimi:hit"))

        // Direct `session.get` merge path used by the notification-tap lookup.
        store.patchSession(try session(key: "kimi:tap", title: "推送", runtime: "kimi"))
        XCTAssertNil(store.session(for: "kimi:tap"))

        let watched = try session(key: "kimi:watch", title: "监视", runtime: "kimi")
        store.rememberOpened(watched)
        store.applySessionEvent(watched, revision: 2)
        XCTAssertNil(store.session(for: "kimi:watch"))
        XCTAssertFalse(store.sections.flatMap(\.sessions).map(\.key).contains("kimi:watch"))

        // Active sessions still merge through every path.
        store.applySessionEvent(try session(key: "claude:a", title: "Live", runtime: "claude"), revision: 3)
        XCTAssertEqual(store.session(for: "claude:a")?.title, "Live")
    }

    func testMigrationAfterCanonicalPatchKeepsOneRow() throws {
        // The host can announce the canonical key before the client migrates
        // the provisional one; the list must not then hold the session twice.
        let store = SessionListStore()
        store.applyListResponse(
            SessionsListResponse(sessions: [try session(key: "claude:tmp", title: "Draft")], version: "v1"),
            persist: false
        )
        store.applySessionEvent(try session(key: "claude:real", title: "Named"), revision: 2)
        store.migrateSession(from: "claude:tmp", to: "claude:real")
        XCTAssertEqual(store.windowSessions.map(\.key), ["claude:real"])
        XCTAssertEqual(store.sections.flatMap(\.sessions).map(\.key), ["claude:real"])
    }

    func testListWindowWithAliasedAndRepeatedKeysKeepsOneRowEach() throws {
        let store = SessionListStore()
        store.migrateSession(from: "claude:tmp", to: "claude:real")
        store.applyListResponse(
            SessionsListResponse(sessions: [
                try session(key: "claude:tmp", title: "Old"),
                try session(key: "claude:real", title: "Named"),
                try session(key: "claude:other", title: "Other"),
                try session(key: "claude:other", title: "Other"),
            ], version: "v2"),
            persist: false
        )
        XCTAssertEqual(store.windowSessions.map(\.key), ["claude:real", "claude:other"])
    }

    func testDormantAliasAndWaitingCountStayHidden() throws {
        let store = SessionListStore()
        store.updateSessions([
            try session(key: "claude:a", title: "A", runtime: "claude", attention: "waiting"),
            try session(key: "kimi:old", title: "旧", runtime: "kimi", attention: "waiting"),
        ])
        XCTAssertEqual(store.waitingCount, 1)

        // A tapped dormant key aliased to a dormant canonical identity resolves nowhere.
        store.migrateSession(from: "kimi:tap", to: "kimi:kept-history")
        XCTAssertNil(store.session(for: "kimi:tap"))
        XCTAssertNil(store.session(for: "kimi:kept-history"))
        XCTAssertFalse(store.sections.flatMap(\.sessions).contains { $0.runtime == "kimi" })
    }

    func testDormantIdentityKeyHidesWithoutRuntime() throws {
        // Runtime is optional in wire/history shapes: the kimi key prefix alone
        // must hide the row from every path and keep it unroutable.
        let store = SessionListStore()
        store.updateSessions([
            try session(key: "kimi:missing-runtime", title: "旧"),
            try session(key: "claude:active", title: "现行", runtime: "claude"),
        ])
        XCTAssertFalse(store.sections.flatMap(\.sessions).map(\.key).contains("kimi:missing-runtime"))
        XCTAssertNil(store.session(for: "kimi:missing-runtime"))
        XCTAssertNotNil(store.session(for: "claude:active"))

        // Legacy cache snapshot carrying the key-only dormant row.
        SessionListCache.save(
            hostID: "host-key-only",
            snapshot: SessionListSnapshot(
                version: "legacy",
                sessions: [
                    try session(key: "kimi:missing-runtime", title: "旧"),
                    try session(key: "claude:active", title: "现行", runtime: "claude"),
                ]
            )
        )
        let cached = SessionListStore()
        cached.loadPersisted(hostID: "host-key-only")
        XCTAssertNil(cached.session(for: "kimi:missing-runtime"))
        XCTAssertNotNil(cached.session(for: "claude:active"))

        // Search, direct patch (tap lookup path), events, and aliases.
        store.applySearchHits([try session(key: "kimi:missing-runtime", title: "旧")], query: "旧")
        XCTAssertNil(store.session(for: "kimi:missing-runtime"))
        store.patchSession(try session(key: "kimi:missing-runtime", title: "旧"))
        XCTAssertNil(store.session(for: "kimi:missing-runtime"))
        let watched = try session(key: "kimi:missing-runtime", title: "旧")
        store.rememberOpened(watched)
        store.applySessionEvent(watched, revision: 2)
        XCTAssertNil(store.session(for: "kimi:missing-runtime"))
        store.migrateSession(from: "kimi:tap", to: "kimi:missing-runtime")
        XCTAssertNil(store.session(for: "kimi:tap"))
    }

    func testOpeningClearsRedDotBeforeHostConfirms() {
        let store = SessionListStore()
        let red = SessionSummary(key: "claude:r", mtime: 100, attention: .unread, marker: "unread")
        store.updateSessions([red])
        store.markReadLocally(key: "claude:r")
        XCTAssertEqual(store.session(for: "claude:r")?.attention, AttentionKind.none)
        XCTAssertEqual(store.session(for: "claude:r")?.marker, "")
        XCTAssertNil(SessionPresentation.statusMarker(for: store.windowSessions[0]))

        // A host push sent before it processed markRead must not repaint the dot.
        store.applySessionEvent(red)
        XCTAssertNil(SessionPresentation.statusMarker(for: store.session(for: "claude:r")!))

        // Newer activity is a new result: the dot comes back.
        store.applySessionEvent(SessionSummary(key: "claude:r", mtime: 200, attention: .unread, marker: "unread"))
        XCTAssertEqual(SessionPresentation.statusMarker(for: store.session(for: "claude:r")!), .unread)
    }

    func testScrollingAcknowledgesEachNewResultOnceWithoutTouchingOtherSessions() throws {
        let store = SessionListStore()
        let key = "claude:reading"
        let first = SessionSummary(key: key, mtime: 100, attention: .unread, marker: "unread")
        let other = SessionSummary(key: "codex:other", mtime: 100, attention: .unread, marker: "unread")
        store.updateSessions([first, other])
        store.rememberOpened(first)
        XCTAssertTrue(store.markReadLocally(key: key))
        let epoch = store.metadataEpoch
        for _ in 0..<120 { XCTAssertFalse(store.markReadLocally(key: key)) }
        XCTAssertEqual(store.metadataEpoch, epoch, "Scrolling frames must not rebuild or persist read state")
        store.applySessionEvent(first)
        XCTAssertFalse(store.markReadLocally(key: key), "Stale echoes must not send another read request")
        let untouched = try XCTUnwrap(store.session(for: other.key))
        XCTAssertEqual(SessionPresentation.statusMarker(for: untouched), .unread)

        // New output while the detail remains open can be read by the next scroll.
        store.applySessionEvent(SessionSummary(key: key, mtime: 200, attention: .unread, marker: "unread"))
        XCTAssertTrue(store.markReadLocally(key: key))
        XCTAssertFalse(store.markReadLocally(key: key))
        let detail = try XCTUnwrap(store.session(for: key))
        let row = try XCTUnwrap(store.windowSessions.first { $0.key == key })
        XCTAssertNil(SessionPresentation.statusMarker(for: detail))
        XCTAssertNil(SessionPresentation.statusMarker(for: row))
        XCTAssertFalse(store.markReadLocally(key: "claude:missing"))
    }

    func testOpeningLeavesWaitingAndWorkingDots() {
        let store = SessionListStore()
        store.updateSessions([
            SessionSummary(key: "claude:w", mtime: 1, attention: .waiting, marker: "waiting"),
            SessionSummary(key: "claude:g", mtime: 1, attention: .working, marker: "working"),
        ])
        XCTAssertFalse(store.markReadLocally(key: "claude:w"))
        XCTAssertFalse(store.markReadLocally(key: "claude:g"))
        XCTAssertEqual(SessionPresentation.statusMarker(for: store.session(for: "claude:w")!), .waiting)
        XCTAssertEqual(SessionPresentation.statusMarker(for: store.session(for: "claude:g")!), .working)
    }

    func testClearingRedPreservesActivityBehindIt() {
        let store = SessionListStore()
        store.updateSessions([
            SessionSummary(key: "claude:d", mtime: 100, attention: .working, marker: "unread"),
            SessionSummary(key: "claude:w", mtime: 100, attention: .waiting, marker: "unread"),
        ])
        XCTAssertTrue(store.markReadLocally(key: "claude:d"))
        let dual = store.session(for: "claude:d")!
        XCTAssertEqual(dual.attention, AttentionKind.working)
        XCTAssertEqual(dual.marker, "")
        XCTAssertEqual(SessionPresentation.activityMarker(for: dual), .working)
        XCTAssertFalse(SessionPresentation.hasUnread(for: dual))
        XCTAssertTrue(SessionListFiltering.isActive(dual))
        // The same host echo (same activity time) must not repaint red…
        store.applySessionEvent(SessionSummary(key: "claude:d", mtime: 100, attention: .working, marker: "unread"))
        XCTAssertFalse(SessionPresentation.hasUnread(for: store.session(for: "claude:d")!))
        XCTAssertEqual(SessionPresentation.activityMarker(for: store.session(for: "claude:d")!), .working)
        // …while newer activity brings red back on top of green.
        store.applySessionEvent(SessionSummary(key: "claude:d", mtime: 200, attention: .working, marker: "unread"))
        XCTAssertTrue(SessionPresentation.hasUnread(for: store.session(for: "claude:d")!))
        XCTAssertEqual(SessionPresentation.activityMarker(for: store.session(for: "claude:d")!), .working)

        // Yellow behind red stays in the waiting section after the read.
        XCTAssertTrue(store.markReadLocally(key: "claude:w"))
        let waited = store.session(for: "claude:w")!
        XCTAssertEqual(SessionPresentation.activityMarker(for: waited), .waiting)
        XCTAssertTrue(store.sections.contains {
            if case .waiting(let items) = $0 { return items.map(\.key).contains("claude:w") }
            return false
        })
        XCTAssertEqual(store.waitingCount, 1)
    }

    func testHostConfirmationEndsLocalReadHold() {
        let store = SessionListStore()
        store.updateSessions([SessionSummary(key: "claude:r", mtime: 100, attention: .unread, marker: "unread")])
        store.markReadLocally(key: "claude:r")
        store.applySessionEvent(SessionSummary(key: "claude:r", mtime: 100, attention: .none, marker: ""))
        // Hold released: a later unread at the same activity time is the host's truth.
        store.applySessionEvent(SessionSummary(key: "claude:r", mtime: 100, attention: .unread, marker: "unread"))
        XCTAssertEqual(SessionPresentation.statusMarker(for: store.session(for: "claude:r")!), .unread)
    }

    private func session(
        key: String,
        title: String,
        runtime: String? = nil,
        attention: String = "none"
    ) throws -> SessionSummary {
        try RemoteJSONDecoder.decode(
            SessionSummary.self,
            from: sessionDict(key: key, title: title, runtime: runtime, attention: attention)
        )
    }

    private func sessionDict(
        key: String,
        title: String,
        runtime: String? = nil,
        attention: String = "none"
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "key": key,
            "title": title,
            "cwd": "/tmp/p",
            "cwd_display": "/tmp/p",
            "mtime": 1_700_000_000,
            "time": "12:00",
            "size_kb": 1,
            "status": "ended",
            "live": false,
            "hosted": false,
            "attention": attention,
            "last_user": "问",
            "last_agent": "答",
            "rich": false,
            "pinned": false,
        ]
        if let runtime { dict["runtime"] = runtime }
        return dict
    }
}
