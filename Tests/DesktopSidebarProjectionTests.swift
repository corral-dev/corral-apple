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

    func testGroupNeedsTwoVisibleMembersElseMembersStandAlone() {
        let group = DesktopGroup(id: "g", name: "Group Apple", members: ["a", "b"])
        let layout = DesktopLayout(revision: 1, groups: [group], pinnedSessions: [:])
        let sessions = [session("a", hoursAgo: 1, title: "alpha"), session("b", hoursAgo: 2, title: "beta")]
        var order = DesktopSidebarProjection.StableOrder()
        let both = DesktopSidebarProjection.sections(
            sessions: sessions, layout: layout, filter: "", order: &order, now: now, calendar: calendar
        )
        XCTAssertEqual(both.flatMap(\.items).map(\.id), ["group:g"])

        var filteredOrder = DesktopSidebarProjection.StableOrder()
        let filtered = DesktopSidebarProjection.sections(
            sessions: sessions, layout: layout, filter: "alpha", order: &filteredOrder, now: now, calendar: calendar
        )
        XCTAssertEqual(filtered.flatMap(\.items).map(\.id), ["session:a"])
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
        var keys: [String] = []
        for item in result.flatMap(\.items) {
            switch item {
            case .session(let session): keys.append(session.key)
            case .group(_, let members): keys.append(contentsOf: members.map(\.key))
            }
        }
        XCTAssertEqual(keys.sorted(), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(result.flatMap(\.items).map(\.id), ["group:g1", "group:g2", "session:e", "session:f"])
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

    func testAttentionSummaryCountsUnreadIndependentlyFromActivity() {
        let members = [
            SessionSummary(key: "a", attention: .waiting, marker: "waiting"),
            SessionSummary(key: "b", attention: .working, marker: "unread"),
            SessionSummary(key: "c", attention: .unread, marker: "unread"),
            SessionSummary(key: "d", attention: .none, marker: "recent"),
            SessionSummary(key: "e"),
        ]
        let summary = DesktopSidebarProjection.attentionSummary(members)
        // waiting: a; working: b (behind red) + d (recent shares green);
        // unread: b + c. One session can count in two buckets.
        XCTAssertEqual(summary.map(\.0), [.waiting, .working, .unread])
        XCTAssertEqual(summary.map(\.1), [1, 2, 2])
    }

    func testGroupArrivingAfterFirstRenderKeepsItsMembersPlace() {
        var order = DesktopSidebarProjection.StableOrder()
        let sessions = [session("live", hoursAgo: 0.1), session("a", hoursAgo: 4), session("b", hoursAgo: 5)]
        _ = DesktopSidebarProjection.sections(sessions: sessions, layout: .empty, filter: "", order: &order, now: now, calendar: calendar)
        let layout = DesktopLayout(revision: 2, groups: [DesktopGroup(id: "g", name: "Group Pear", members: ["a", "b"])], pinnedSessions: [:])
        let result = DesktopSidebarProjection.sections(sessions: sessions, layout: layout, filter: "", order: &order, now: now, calendar: calendar)
        XCTAssertEqual(result.first?.items.map(\.id), ["session:live", "group:g"])
    }
}
