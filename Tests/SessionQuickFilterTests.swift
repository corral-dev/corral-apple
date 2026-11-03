import XCTest
@testable import Corral

final class SessionQuickFilterTests: XCTestCase {
    @MainActor
    func testRepeatedCycleAndModeLabels() {
        var mode = SessionQuickFilter.all
        for _ in 0..<3 {
            XCTAssertEqual(mode, .all)
            XCTAssertEqual(mode.titleKey, "sessions.filter.attention")
            mode.advance()
            XCTAssertEqual(mode, .attention)
            XCTAssertEqual(mode.titleKey, "sessions.filter.attention")
            mode.advance()
            XCTAssertEqual(mode, .active)
            XCTAssertEqual(mode.titleKey, "sessions.filter.active")
            mode.advance()
        }
        XCTAssertEqual(mode, .all)
    }

    @MainActor
    func testMembershipCountsIntersectionsAndGroupedSections() {
        let sessions = [
            SessionSummary(key: "codex:working", runtime: "codex", cwd: "/work/one", attention: .working, marker: "working", needsAttention: true),
            SessionSummary(key: "claude:waiting", runtime: "claude", cwd: "/work/two", attention: .waiting, marker: "waiting", needsAttention: true),
            SessionSummary(key: "pi:recent", runtime: "pi", cwd: "/work/one", marker: "recent", needsAttention: true),
            SessionSummary(key: "codex:unread", runtime: "codex", cwd: "/work/one", attention: .unread, marker: "unread", needsAttention: true),
            SessionSummary(key: "pi:opened", runtime: "pi", marker: "", needsAttention: true),
            SessionSummary(key: "cursor:idle", runtime: "cursor", live: true, marker: "", needsAttention: false),
            SessionSummary(key: "codex:dual", runtime: "codex", cwd: "/work/one", attention: .working, marker: "unread", needsAttention: true),
            SessionSummary(key: "kimi:dormant", runtime: "kimi", attention: .working, marker: "working", needsAttention: true),
        ]
        XCTAssertEqual(SessionQuickFilter.all.apply(sessions: sessions).count, 7)
        XCTAssertEqual(SessionQuickFilter.all.count(sessions: sessions), 6)
        XCTAssertEqual(SessionQuickFilter.attention.count(sessions: sessions), 6)
        XCTAssertEqual(SessionQuickFilter.active.apply(sessions: sessions).map(\.key), [
            "codex:working", "claude:waiting", "pi:recent", "codex:dual",
        ])
        XCTAssertEqual(SessionQuickFilter.active.count(sessions: sessions), 4)
        let filtered = SessionQuickFilter.active.apply(
            sessions: sessions, runtimes: [.codex], projects: [.project(path: "/work/one")]
        )
        XCTAssertEqual(filtered.map(\.key), ["codex:working", "codex:dual"])
        let sections: [SessionListStore.Section] = [.pinned([sessions[3]]), .today(sessions)]
        let activeSections = SessionQuickFilter.active.apply(to: sections)
        XCTAssertEqual(activeSections.count, 1)
        XCTAssertEqual(activeSections.flatMap(\.sessions).map(\.key), SessionQuickFilter.active.apply(sessions: sessions).map(\.key))
        for mode in SessionQuickFilter.allCases {
            XCTAssertTrue(mode.apply(sessions: []).isEmpty)
            XCTAssertTrue(mode.apply(to: []).isEmpty)
            XCTAssertEqual(mode.count(sessions: []), 0)
        }
    }
}
