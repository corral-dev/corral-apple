import XCTest
@testable import Corral

@MainActor
final class DesktopSidebarProjectionTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    /// Sunday 2026-10-04 15:00 +08:00.
    private var now: Date { Date(timeIntervalSince1970: 1_791_097_200) }

    private func session(_ key: String, hoursAgo: Double, live: Bool = false, title: String = "", cwd: String = "/p") -> SessionSummary {
        SessionSummary(
            key: key, runtime: "claude", title: title.isEmpty ? key : title, cwd: cwd,
            mtime: now.timeIntervalSince1970 - hoursAgo * 3600, live: live
        )
    }

    func testSplitMembersRemainFlatAndRetainMembershipWhenFiltered() {
        let group = DesktopGroup(id: "g", name: "Group Apple", members: ["a", "b"])
        let layout = DesktopLayout(revision: 1, groups: [group], pinnedSessions: [:])
        let sessions = [session("a", hoursAgo: 1, title: "alpha"), session("b", hoursAgo: 2, title: "beta")]
        var order = DesktopSidebarProjection.StableOrder()
        let both = DesktopSidebarProjection.sections(
            sessions: sessions, layout: layout, filter: "", order: &order, now: now, calendar: calendar
        )
        XCTAssertEqual(both.flatMap(\.items).map(\.id), ["session:a", "session:b"])

        var filteredOrder = DesktopSidebarProjection.StableOrder()
        let filtered = DesktopSidebarProjection.sections(
            sessions: sessions, layout: layout, filter: "alpha", order: &filteredOrder, now: now, calendar: calendar
        )
        XCTAssertEqual(filtered.flatMap(\.items).map(\.id), ["session:a"])
        XCTAssertEqual(filtered.first?.items.first?.split?.id, "g")
    }

    func testEachSessionAppearsOnceWithRepeatedInputAndOverlappingGroups() {
        // A layout briefly listing a session in two groups, or a repeated
        // session record, must never yield two rows with one identity.
        let layout = DesktopLayout(revision: 1, groups: [
            DesktopGroup(id: "g1", name: "Group Apple", members: ["a", "b"]),
            DesktopGroup(id: "g2", name: "Group Pear", members: ["b", "c", "d"]),
            DesktopGroup(id: "g3", name: "Group Fig", members: ["e", "e"]),
        ], pinnedSessions: [:])
        let sessions = ["a", "b", "c", "d", "e", "f", "f"].map { session($0, hoursAgo: 1) }
        var order = DesktopSidebarProjection.StableOrder()
        let result = DesktopSidebarProjection.sections(
            sessions: sessions, layout: layout, filter: "", order: &order, now: now, calendar: calendar
        )
        let keys = result.flatMap(\.items).map { $0.session.key }
        XCTAssertEqual(keys.sorted(), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(result.flatMap(\.items).count, 6)
        XCTAssertEqual(result.flatMap(\.items).first { $0.session.key == "b" }?.split?.id, "g1")
    }

    func testFilterNeverMatchesSplitIdentity() {
        // Splits are never named: the hidden internal fruit identity never matches.
        let sessions = [session("a", hoursAgo: 1), session("b", hoursAgo: 1), session("c", hoursAgo: 1)]
        let layout = DesktopLayout(revision: 1, groups: [DesktopGroup(id: "g", name: "Group Cherry", members: ["a", "b"])], pinnedSessions: [:])
        var order = DesktopSidebarProjection.StableOrder()
        let hidden = DesktopSidebarProjection.sections(
            sessions: sessions, layout: layout, filter: "cherry", order: &order, now: now, calendar: calendar
        )
        XCTAssertTrue(hidden.flatMap(\.items).isEmpty)
    }

    func testPinnedBlockFirstNewestPinFirst() {
        let layout = DesktopLayout(revision: 1, groups: [], pinnedSessions: ["old": 10, "new": 20])
        var order = DesktopSidebarProjection.StableOrder()
        let result = DesktopSidebarProjection.sections(
            sessions: [session("old", hoursAgo: 1), session("new", hoursAgo: 50), session("plain", hoursAgo: 1)],
            layout: layout, filter: "", order: &order, now: now, calendar: calendar
        )
        XCTAssertEqual(result.first?.kind, .pinned)
        XCTAssertEqual(result.first?.items.map(\.id), ["session:new", "session:old"])
        XCTAssertEqual(result.last?.items.map(\.id), ["session:plain"])
    }

    func testLocalCalendarBuckets() {
        var order = DesktopSidebarProjection.StableOrder()
        let result = DesktopSidebarProjection.sections(
            sessions: [
                session("today", hoursAgo: 2),
                session("yesterday", hoursAgo: 20),
                session("friday", hoursAgo: 50),
                session("old", hoursAgo: 24 * 30),
                session("live-old", hoursAgo: 24 * 30, live: true),
            ],
            layout: .empty, filter: "", order: &order, now: now, calendar: calendar
        )
        XCTAssertEqual(result.map(\.id), ["today", "yesterday", "weekday-6", "older"])
        XCTAssertEqual(Set(result[0].items.map(\.id)), ["session:today"])
        XCTAssertEqual(Set(result.last!.items.map(\.id)), ["session:old", "session:live-old"])
    }

    func testLiveGroupUsesActivityAndMovesAcrossMidnightWithoutMetadataChanges() {
        let group = DesktopGroup(id: "g", name: "", members: ["a", "b"])
        let layout = DesktopLayout(revision: 0, groups: [group], pinnedSessions: [:])
        let sessions = [session("a", hoursAgo: 1, live: true), session("b", hoursAgo: 2, live: true)]
        var order = DesktopSidebarProjection.StableOrder()
        let before = DesktopSidebarProjection.sections(sessions: sessions, layout: layout, filter: "", order: &order, now: now, calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let after = DesktopSidebarProjection.sections(sessions: sessions, layout: layout, filter: "", order: &order, now: nextDay, calendar: calendar)
        XCTAssertEqual(before.map(\.id), ["today"])
        XCTAssertEqual(after.map(\.id), ["yesterday"])
        XCTAssertEqual(before.first?.items.map(\.id), after.first?.items.map(\.id))
    }

    func testStableOrderKeepsShownRowsAndInsertsOldNewcomersByTime() {
        var order = DesktopSidebarProjection.StableOrder()
        var sessions = [session("a", hoursAgo: 1), session("b", hoursAgo: 2)]
        _ = DesktopSidebarProjection.sections(sessions: sessions, layout: .empty, filter: "", order: &order, now: now, calendar: calendar)
        // b becomes newest by mtime; a new session c appears.
        sessions = [session("a", hoursAgo: 1), session("b", hoursAgo: 0.1), session("c", hoursAgo: 3)]
        let result = DesktopSidebarProjection.sections(sessions: sessions, layout: .empty, filter: "", order: &order, now: now, calendar: calendar)
        XCTAssertEqual(result.first?.items.map(\.id), ["session:a", "session:b", "session:c"])
    }

    func testNewSessionStillPrecedesExistingRows() {
        var order = DesktopSidebarProjection.StableOrder()
        let existing = [session("a", hoursAgo: 1), session("b", hoursAgo: 2)]
        _ = DesktopSidebarProjection.sections(sessions: existing, layout: .empty, filter: "", order: &order, now: now, calendar: calendar)
        let result = DesktopSidebarProjection.sections(sessions: existing + [session("new", hoursAgo: 0), session("empty", hoursAgo: 12, live: true)], layout: .empty, filter: "", order: &order, now: now, calendar: calendar)
        XCTAssertEqual(result.first?.items.map(\.id), ["session:new", "session:a", "session:b", "session:empty"])
    }

    func testGroupArrivingAfterFirstRenderKeepsItsMembersPlace() {
        var order = DesktopSidebarProjection.StableOrder()
        let sessions = [session("live", hoursAgo: 0.1), session("a", hoursAgo: 4), session("b", hoursAgo: 5)]
        _ = DesktopSidebarProjection.sections(sessions: sessions, layout: .empty, filter: "", order: &order, now: now, calendar: calendar)
        let layout = DesktopLayout(revision: 2, groups: [DesktopGroup(id: "g", name: "Group Pear", members: ["a", "b"])], pinnedSessions: [:])
        let result = DesktopSidebarProjection.sections(sessions: sessions, layout: layout, filter: "", order: &order, now: now, calendar: calendar)
        XCTAssertEqual(result.first?.items.map(\.id), ["session:live", "session:a", "session:b"])
    }

    func testCollapsedSplitKeepsEveryMemberInItsOwnDateBucket() {
        let group = DesktopGroup(id: "g", name: "", members: ["a", "b"], collapsed: true)
        var order = DesktopSidebarProjection.StableOrder()
        let result = DesktopSidebarProjection.sections(
            sessions: [session("a", hoursAgo: 1), session("b", hoursAgo: 20)],
            layout: DesktopLayout(revision: 1, groups: [group], pinnedSessions: [:]),
            filter: "", order: &order, now: now, calendar: calendar
        )
        XCTAssertEqual(result.map(\.id), ["today", "yesterday"])
        XCTAssertEqual(result.flatMap(\.items).map(\.id), ["session:a", "session:b"])
        XCTAssertTrue(result.flatMap(\.items).allSatisfy { $0.split?.collapsed == true })
    }

    func testPinnedSplitExposesFlatMembersAndPreservesIndividualPinTimes() {
        let group = DesktopGroup(id: "g", name: "", members: ["a", "b"], pinned: true, pinnedAt: 20)
        var order = DesktopSidebarProjection.StableOrder()
        let result = DesktopSidebarProjection.sections(
            sessions: [session("a", hoursAgo: 1), session("b", hoursAgo: 2), session("c", hoursAgo: 3)],
            layout: DesktopLayout(revision: 1, groups: [group], pinnedSessions: ["b": 30, "c": 10]),
            filter: "", order: &order, now: now, calendar: calendar
        )
        XCTAssertEqual(result.map(\.id), ["pinned"])
        XCTAssertEqual(result.first?.items.map(\.id), ["session:b", "session:a", "session:c"])
    }

    func testJoiningLeavingAndCollapsingSplitNeverMovesRows() {
        let sessions = [session("a", hoursAgo: 1), session("c", hoursAgo: 2), session("b", hoursAgo: 3)]
        var order = DesktopSidebarProjection.StableOrder()
        let baseline = DesktopSidebarProjection.sections(
            sessions: sessions, layout: .empty, filter: "", order: &order, now: now, calendar: calendar
        ).flatMap(\.items).map(\.id)
        for collapsed in [false, true] {
            let group = DesktopGroup(id: "g", name: "", members: ["b", "a"], collapsed: collapsed)
            let result = DesktopSidebarProjection.sections(
                sessions: sessions, layout: DesktopLayout(revision: 2, groups: [group], pinnedSessions: [:]),
                filter: "", order: &order, now: now, calendar: calendar
            )
            XCTAssertEqual(result.flatMap(\.items).map(\.id), baseline)
        }
        let dissolved = DesktopSidebarProjection.sections(
            sessions: sessions, layout: .empty, filter: "", order: &order, now: now, calendar: calendar
        )
        XCTAssertEqual(dissolved.flatMap(\.items).map(\.id), baseline)
        XCTAssertTrue(dissolved.flatMap(\.items).allSatisfy { $0.split == nil })
    }

    /// Full-text matches carry the sessions.list summary; older hosts omit it.
    func testFulltextMatchDecodesOptionalSessionSummary() throws {
        let json = """
        {"total": 2, "matches": [
          {"key": "codex:a", "title": "Store review", "total_hits": 3,
           "session": {"key": "codex:a", "runtime": "codex", "title": "Store review",
                       "cwd": "/work/Corral", "cwd_display": "/work/Corral", "mtime": 1791097200.5},
           "lines": [{"role": "assistant", "text": "isolated VM", "spans": [[9, 11]], "ts": 1.0}]},
          {"key": "claude:b", "title": "Old host", "total_hits": 1, "lines": []}
        ]}
        """
        let response = try JSONDecoder().decode(FulltextSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.matches.count, 2)
        let session = try XCTUnwrap(response.matches[0].session)
        XCTAssertEqual(session.runtime, "codex")
        XCTAssertEqual(session.mtime, 1_791_097_200.5)
        XCTAssertEqual(SessionPresentation.projectName(from: session), "Corral")
        XCTAssertEqual(response.matches[0].lines.first?.spans, [[9, 11]])
        XCTAssertNil(response.matches[1].session)
    }
}
