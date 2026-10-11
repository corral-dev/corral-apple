import Foundation
import XCTest
@testable import Corral

/// Session-list runtime/project quick-filter regressions, through the actual
/// production filter path (`SessionListFiltering` — the same functions the
/// list view renders) and the actual `SessionListStore` search path.
@MainActor
final class SessionListFilteringTests: XCTestCase {
    func testMultipleRuntimesAndProjectsUnionWithinRowsIntersectWithSearch() throws {
        let store = SessionListStore()
        let sessions = [
            summary(key: "claude:a", title: "Login work", runtime: "claude", cwd: "/tmp/Alpha"),
            summary(key: "codex:b", title: "Login work", runtime: "codex", cwd: "/tmp/Beta"),
            summary(key: "claude:c", title: "Login work", runtime: "claude", cwd: "/tmp/Beta"),
            summary(key: "pi:d", title: "Login work", runtime: "pi", cwd: "/tmp/Alpha"),
            summary(key: "codex:e", title: "Login work", runtime: "codex", cwd: "/tmp/Other"),
            summary(key: "codex:f", title: "Unrelated", runtime: "codex", cwd: "/tmp/Alpha"),
            summary(key: "kimi:g", title: "Login work", runtime: "kimi", cwd: "/tmp/Beta"),
        ]
        store.updateSessions(sessions)
        store.searchQuery = "login"
        let sections = SessionListFiltering.apply(
            to: store.sections,
            runtimes: [.claude, .codex],
            projects: [.project(path: "/tmp/Alpha"), .project(path: "/tmp/Beta")]
        )
        XCTAssertEqual(Set(sections.flatMap(\.sessions).map(\.key)), ["claude:a", "codex:b", "claude:c"])
        XCTAssertEqual(store.windowSessions.count, 6)
        XCTAssertEqual(Set(SessionListFiltering.allOptions(sessions: store.windowSessions).map(\.path)),
                       ["/tmp/Alpha", "/tmp/Beta", "/tmp/Other"])
    }

    func testTogglingOneRuntimePreservesTheOtherAndLastRemovalReturnsAll() {
        let sessions = [
            summary(key: "claude:a", runtime: "claude"),
            summary(key: "codex:b", runtime: "codex", cwd: ""),
            summary(key: "pi:c", runtime: "pi"),
        ]
        var selected: Set<SessionRuntimeFilter> = []
        SessionListFiltering.toggle(.claude, all: .all, in: &selected)
        SessionListFiltering.toggle(.codex, all: .all, in: &selected)
        XCTAssertEqual(SessionListFiltering.apply(sessions: sessions, runtimes: selected, projects: []).count, 2)
        SessionListFiltering.toggle(.claude, all: .all, in: &selected)
        XCTAssertEqual(SessionListFiltering.apply(sessions: sessions, runtimes: selected, projects: []).map(\.key), ["codex:b"])
        SessionListFiltering.toggle(.codex, all: .all, in: &selected)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(SessionListFiltering.apply(sessions: sessions, runtimes: selected, projects: []).count, 3)
    }

    func testProjectAndNoProjectCanBeSelectedTogetherAndAllClearsOnlyProjects() {
        let sessions = [
            summary(key: "codex:a", runtime: "codex", cwd: "/tmp/Alpha"),
            summary(key: "codex:b", runtime: "codex", cwd: ""),
            summary(key: "codex:c", runtime: "codex", cwd: "/tmp/Beta"),
            summary(key: "pi:d", runtime: "pi", cwd: "/tmp/Beta"),
        ]
        var selected: Set<SessionProjectFilter> = []
        SessionListFiltering.toggle(.project(path: "/tmp/Alpha"), all: .all, in: &selected)
        SessionListFiltering.toggle(.noProject, all: .all, in: &selected)
        XCTAssertEqual(SessionListFiltering.apply(sessions: sessions, runtimes: [.codex], projects: selected).map(\.key),
                       ["codex:a", "codex:b"])
        SessionListFiltering.toggle(.project(path: "/tmp/Alpha"), all: .all, in: &selected)
        XCTAssertEqual(SessionListFiltering.apply(sessions: sessions, runtimes: [.codex], projects: selected).map(\.key), ["codex:b"])
        SessionListFiltering.toggle(.all, all: .all, in: &selected)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(SessionListFiltering.apply(sessions: sessions, runtimes: [.codex], projects: selected).map(\.key),
                       ["codex:a", "codex:b", "codex:c"])
    }

    func testRuntimeFilterMatchesOnlyItsOwnID() {
        let claude = summary(key: "claude:a", runtime: "claude")
        XCTAssertTrue(SessionRuntimeFilter.claude.matches(claude))
        XCTAssertFalse(SessionRuntimeFilter.codex.matches(claude))
        XCTAssertTrue(SessionRuntimeFilter.all.matches(claude))
        // Case-insensitive: hosts may report any case.
        XCTAssertTrue(
            SessionRuntimeFilter.cursor.matches(summary(key: "cursor:b", runtime: "CURSOR"))
        )
        // Unknown or missing runtimes only pass under All.
        let unknown = summary(key: "next:x", runtime: "next-agent")
        XCTAssertTrue(SessionRuntimeFilter.all.matches(unknown))
        XCTAssertFalse(SessionRuntimeFilter.pi.matches(unknown))
        let missing = summary(key: "plain:y")
        XCTAssertTrue(SessionRuntimeFilter.all.matches(missing))
        XCTAssertFalse(SessionRuntimeFilter.opencode.matches(missing))
    }

    func testRuntimeProjectSearchIntersect() {
        let sessions = [
            summary(key: "claude:a", title: "Fix login bug", runtime: "claude", cwd: "/tmp/Corral"),
            summary(key: "codex:b", title: "Fix login bug", runtime: "codex", cwd: "/tmp/Corral"),
            summary(key: "claude:c", title: "Unrelated", runtime: "claude", cwd: "/tmp/Other"),
        ]
        let filtered = SessionListFiltering.apply(
            sessions: sessions,
            runtimes: [.claude],
            projects: [.project(path: "/tmp/Corral")]
        ).filter { $0.matches(query: "login") }
        XCTAssertEqual(filtered.map(\.key), ["claude:a"])
    }

    func testCanonicalIdentityPrefersCwdOverDisplayAlias() {
        // Same canonical cwd with different display aliases stays one choice.
        let sessions = [
            summary(key: "claude:a", runtime: "claude", cwd: "/data/P", cwdDisplay: "~/P"),
            summary(key: "codex:b", runtime: "codex", cwd: "/data/P", cwdDisplay: "/data/P"),
        ]
        let options = SessionListFiltering.allOptions(sessions: sessions)
        XCTAssertEqual(options.map(\.path), ["/data/P"])
        XCTAssertEqual(
            SessionListFiltering.apply(
                sessions: sessions,
                runtimes: [],
                projects: [.project(path: "/data/P")]
            ).count,
            2
        )
        // Older hosts that omit cwd fall back to the display path.
        let legacy = [summary(key: "claude:l", runtime: "claude", cwd: "", cwdDisplay: "/legacy/Q")]
        XCTAssertEqual(
            SessionListFiltering.allOptions(sessions: legacy).map(\.path),
            ["/legacy/Q"]
        )
    }

    func testDuplicateLeafNamesStayDistinctWithoutBasenameCollision() {
        let sessions = [
            summary(key: "claude:a", runtime: "claude", cwd: "~/Codes/Alpha/ios"),
            summary(key: "codex:b", runtime: "codex", cwd: "~/Codes/Beta/ios"),
        ]
        // Exact directory identity: each selection matches exactly one row.
        XCTAssertEqual(
            SessionListFiltering.apply(
                sessions: sessions,
                runtimes: [],
                projects: [.project(path: "~/Codes/Alpha/ios")]
            ).map(\.key),
            ["claude:a"]
        )
        let labels = SessionListFiltering.allOptions(sessions: sessions).map(\.label)
        XCTAssertEqual(Set(labels).count, 2)
        XCTAssertTrue(labels.allSatisfy { $0 != "ios" })
    }

    func testIdenticalIntermediateParentsExtendToUniqueSuffix() {
        // Coordinator repro: generic parent/leaf collides, so the longer
        // unique suffix wins even for ambiguous leaves.
        let sessions = [
            summary(key: "claude:a", runtime: "claude", cwd: "/Alpha/shared/ios"),
            summary(key: "codex:b", runtime: "codex", cwd: "/Beta/shared/ios"),
        ]
        let labels = SessionListFiltering.allOptions(sessions: sessions)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: labels.map { ($0.path, $0.label) }),
            [
                "/Alpha/shared/ios": "Alpha / shared / ios",
                "/Beta/shared/ios": "Beta / shared / ios",
            ]
        )
        let cli = [
            summary(key: "claude:c", runtime: "claude", cwd: "/Alpha/shared/cli"),
            summary(key: "codex:d", runtime: "codex", cwd: "/Beta/shared/cli"),
        ]
        let cliLabels = SessionListFiltering.allOptions(sessions: cli)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: cliLabels.map { ($0.path, $0.label) }),
            [
                "/Alpha/shared/cli": "Alpha / shared / cli",
                "/Beta/shared/cli": "Beta / shared / cli",
            ]
        )
        // Distinct parents keep the short generic label.
        let distinct = [
            summary(key: "claude:e", runtime: "claude", cwd: "~/Codes/Alpha/ios"),
            summary(key: "codex:f", runtime: "codex", cwd: "~/Codes/Beta/cli"),
        ]
        let distinctLabels = SessionListFiltering.allOptions(sessions: distinct)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: distinctLabels.map { ($0.path, $0.label) }),
            [
                "~/Codes/Alpha/ios": "Alpha / ios",
                "~/Codes/Beta/cli": "Beta / cli",
            ]
        )
    }

    func testDuplicateSessionsInOneDirectoryDoNotForceFullPaths() {
        let sessions = [
            summary(key: "claude:a", runtime: "claude", cwd: "/tmp/Solo"),
            summary(key: "codex:b", runtime: "codex", cwd: "/tmp/Solo"),
        ]
        XCTAssertEqual(
            SessionListFiltering.allOptions(sessions: sessions).map(\.label),
            ["Solo"]
        )
    }

    func testIndependentCatalogsDoNotShareLabelState() {
        // Seed the shared row-label map, then prove the engine never mutates it.
        let seeded = summary(key: "claude:seed", runtime: "claude", cwd: "/tmp/Seed")
        SessionPresentation.updateDisambiguation(for: [seeded])
        let expectedSeeded = SessionPresentation.projectName(cwd: "/tmp/Seed", key: "claude:seed")

        let catalogA = [summary(key: "claude:a", runtime: "claude", cwd: "~/Codes/Alpha/ios")]
        let catalogB = [summary(key: "codex:b", runtime: "codex", cwd: "~/Codes/Beta/ios")]
        // Call order must not matter: B first, then A.
        let labelsB = SessionListFiltering.labelsByPath(
            catalogB.map { SessionListFiltering.directoryIdentity(of: $0) }
        )
        let labelsA = SessionListFiltering.labelsByPath(
            catalogA.map { SessionListFiltering.directoryIdentity(of: $0) }
        )
        XCTAssertEqual(labelsA["~/Codes/Alpha/ios"], "Alpha / ios")
        XCTAssertEqual(labelsB["~/Codes/Beta/ios"], "Beta / ios")
        // The shared row-label map is untouched by every engine entry point.
        _ = SessionListFiltering.allOptions(sessions: catalogA + catalogB)
        _ = SessionListFiltering.reconcileChoices(
            current: [], sessions: catalogA + catalogB
        )
        _ = SessionListFiltering.option(for: "~/Codes/Alpha/ios", sessions: catalogA)
        XCTAssertEqual(
            SessionPresentation.projectName(cwd: "/tmp/Seed", key: "claude:seed"),
            expectedSeeded
        )
    }

    func testSnapshotKeepsEntireArrayWhenOnlyActivityChanges() {
        func session(project: String, mtime: Double) -> SessionSummary {
            summary(
                key: "claude:\(project)",
                runtime: "claude",
                cwd: "/tmp/\(project)",
                mtime: mtime
            )
        }
        // Six established choices; Quiet is outside the snapshot.
        let window = [
            session(project: "Alpha", mtime: 600),
            session(project: "Beta", mtime: 500),
            session(project: "Gamma", mtime: 400),
            session(project: "Delta", mtime: 300),
            session(project: "Echo", mtime: 200),
            session(project: "Foxtrot", mtime: 100),
            session(project: "Quiet", mtime: 10),
        ]
        let first = SessionListFiltering.reconcileChoices(
            current: [], sessions: window, limit: 6
        )
        XCTAssertEqual(first.map(\.path), [
            "/tmp/Alpha", "/tmp/Beta", "/tmp/Gamma",
            "/tmp/Delta", "/tmp/Echo", "/tmp/Foxtrot",
        ])
        // The formerly quiet project becomes the most recent: activity alone
        // must not evict or shift anything. The ENTIRE array is unchanged;
        // Quiet stays reachable through More.
        let surged = window.map { s in
            s.key == "claude:Quiet" ? session(project: "Quiet", mtime: 700) : s
        }
        let second = SessionListFiltering.reconcileChoices(
            current: first, sessions: surged, limit: 6
        )
        XCTAssertEqual(second, first)
        // Pure churn below the cap never reorders either.
        let reshuffled = SessionListFiltering.reconcileChoices(
            current: second, sessions: surged.reversed(), limit: 6
        )
        XCTAssertEqual(reshuffled, second)
    }

    func testSnapshotFillsVacanciesFromRemovalsOnly() {
        func session(project: String, mtime: Double) -> SessionSummary {
            summary(
                key: "claude:\(project)",
                runtime: "claude",
                cwd: "/tmp/\(project)",
                mtime: mtime
            )
        }
        let window = [
            session(project: "Alpha", mtime: 600),
            session(project: "Beta", mtime: 500),
            session(project: "Gamma", mtime: 400),
            session(project: "Delta", mtime: 300),
            session(project: "Echo", mtime: 200),
            session(project: "Foxtrot", mtime: 100),
            session(project: "Quiet", mtime: 10),
        ]
        let first = SessionListFiltering.reconcileChoices(
            current: [], sessions: window, limit: 6
        )
        // Foxtrot's sessions actually disappear: its vacancy is filled by the
        // present-but-unlisted identity, survivors unmoved.
        let shrunk = window.filter { $0.key != "claude:Foxtrot" }
        let second = SessionListFiltering.reconcileChoices(
            current: first, sessions: shrunk, limit: 6
        )
        XCTAssertEqual(second.map(\.path), [
            "/tmp/Alpha", "/tmp/Beta", "/tmp/Gamma",
            "/tmp/Delta", "/tmp/Echo", "/tmp/Quiet",
        ])
    }

    func testEqualTimestampsBreakTiesByPath() {
        let sessions = [
            summary(key: "claude:b", runtime: "claude", cwd: "/tmp/Beta", mtime: 100),
            summary(key: "claude:a", runtime: "claude", cwd: "/tmp/Alpha", mtime: 100),
        ]
        let choices = SessionListFiltering.reconcileChoices(
            current: [], sessions: sessions, limit: 2
        )
        XCTAssertEqual(choices.map(\.path), ["/tmp/Alpha", "/tmp/Beta"])
    }

    func testSnapshotUpdatesLabelsWithoutMovingChoices() {
        let one = summary(key: "claude:a", runtime: "claude", cwd: "~/Codes/Alpha/ios")
        let first = SessionListFiltering.reconcileChoices(
            current: [], sessions: [one]
        )
        XCTAssertEqual(first.map(\.label), ["Alpha / ios"])
        // A duplicate leaf arrives: the kept choice refreshes its context
        // label in place instead of shifting.
        let two = one // same session, plus a same-leaf sibling host dir
        let sibling = summary(key: "codex:b", runtime: "codex", cwd: "~/Codes/Beta/ios")
        let second = SessionListFiltering.reconcileChoices(
            current: first, sessions: [two, sibling]
        )
        XCTAssertEqual(second.map(\.path), ["~/Codes/Alpha/ios", "~/Codes/Beta/ios"])
    }

    func testStoreSearchNarrowsRowsButNotChoices() throws {
        let store = SessionListStore()
        store.updateSessions([
            summary(key: "claude:a", title: "Alpha work", runtime: "claude", cwd: "/tmp/Alpha"),
            summary(key: "codex:b", title: "Beta work", runtime: "codex", cwd: "/tmp/Beta"),
            summary(key: "claude:g", title: "Gamma work", runtime: "claude", cwd: "/tmp/Gamma"),
        ])
        XCTAssertEqual(store.windowSessions.count, 3)

        // Narrowing text search through the actual store path empties the
        // displayed rows...
        store.searchQuery = "zzz-nothing-matches"
        XCTAssertTrue(store.sections.isEmpty)

        // ...while the unfiltered host window keeps every choice available
        // and the selected identity still resolves.
        let window = store.windowSessions
        XCTAssertEqual(window.count, 3)
        let choices = SessionListFiltering.reconcileChoices(
            current: [], sessions: window
        )
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(
            SessionListFiltering.apply(
                sessions: window,
                runtimes: [],
                projects: [.project(path: "/tmp/Beta")]
            ).map(\.key),
            ["codex:b"]
        )
        XCTAssertFalse(SessionListFiltering.hasNoProject(sessions: []))
    }

    func testNoProjectSessionsStayReachable() {
        let sessions = [
            summary(key: "claude:a", runtime: "claude", cwd: ""),
            summary(key: "codex:b", runtime: "codex", cwd: "/tmp/P"),
        ]
        XCTAssertTrue(SessionListFiltering.hasNoProject(sessions: sessions))
        XCTAssertFalse(SessionListFiltering.hasNoProject(sessions: [sessions[1]]))
        let onlyBare = SessionListFiltering.apply(
            sessions: sessions,
            runtimes: [],
            projects: [.noProject]
        )
        XCTAssertEqual(onlyBare.map(\.key), ["claude:a"])
        // No-project sessions never appear as project choices, but remain
        // listed under All.
        XCTAssertTrue(
            SessionListFiltering.allOptions(sessions: sessions).map(\.path).allSatisfy { !$0.isEmpty }
        )
        XCTAssertEqual(
            SessionListFiltering.apply(sessions: sessions, runtimes: [], projects: []).count,
            2
        )
    }

    func testApplyToSectionsDropsEmptySectionsAndKeepsCounts() throws {
        let store = SessionListStore()
        store.updateSessions([
            summary(key: "claude:a", runtime: "claude", cwd: "/tmp/P", attention: "waiting"),
            summary(key: "codex:b", runtime: "codex", cwd: "/tmp/P"),
            summary(key: "claude:c", runtime: "claude", cwd: "/tmp/Q"),
        ])
        XCTAssertFalse(store.sections.isEmpty)
        let filtered = SessionListFiltering.apply(
            to: store.sections,
            runtimes: [.codex],
            projects: [.project(path: "/tmp/P")]
        )
        let rows = filtered.flatMap(\.sessions)
        XCTAssertEqual(rows.map(\.key), ["codex:b"])
        // Every surviving section is non-empty: headers match visible rows.
        XCTAssertTrue(filtered.allSatisfy { !$0.sessions.isEmpty })
        XCTAssertEqual(
            filtered.reduce(0) { $0 + $1.sessions.count },
            rows.count
        )
        // A combination matching nothing yields no sections (empty-filter UI),
        // never a silent partial list.
        let none = SessionListFiltering.apply(
            to: store.sections,
            runtimes: [.pi],
            projects: []
        )
        XCTAssertTrue(none.isEmpty)
    }

    func testDormantIdentitiesExcludedThroughProductionPath() {
        let sessions = [
            summary(key: "kimi:kept", title: "旧", runtime: "kimi"),
            summary(key: "kimi:key-only", title: "旧"),
            summary(key: "claude:a", title: "A", runtime: "claude"),
            summary(key: "next:f", title: "F", runtime: "next-agent"),
            summary(key: "noruntime:g", title: "G"),
        ]
        let visible = SessionListFiltering.apply(
            sessions: sessions,
            runtimes: [],
            projects: []
        )
        XCTAssertFalse(visible.map(\.key).contains("kimi:kept"))
        XCTAssertFalse(visible.map(\.key).contains("kimi:key-only"))
        for key in ["claude:a", "next:f", "noruntime:g"] {
            XCTAssertTrue(visible.map(\.key).contains(key), key)
        }
        // Dormant sessions never become project choices either.
        XCTAssertTrue(
            SessionListFiltering.allOptions(sessions: sessions).allSatisfy {
                !$0.path.lowercased().contains("kimi")
            }
        )
        XCTAssertFalse(SessionListFiltering.hasNoProject(sessions: sessions))
    }

    func testTrailingSlashDoesNotSplitProjectIdentity() {
        let sessions = [
            summary(key: "claude:a", runtime: "claude", cwd: "/tmp/P/"),
            summary(key: "codex:b", runtime: "codex", cwd: "/tmp/P"),
        ]
        let options = SessionListFiltering.allOptions(sessions: sessions)
        XCTAssertEqual(options.count, 1)
        let filtered = SessionListFiltering.apply(
            sessions: sessions,
            runtimes: [],
            projects: [.project(path: "/tmp/P")]
        )
        XCTAssertEqual(filtered.count, 2)
    }

    func testSelectedOutsideSnapshotStaysLabelled() {
        let sessions = [
            summary(key: "claude:a", runtime: "claude", cwd: "/tmp/Alpha", mtime: 300),
            summary(key: "claude:q", runtime: "claude", cwd: "/tmp/Quiet", mtime: 100),
        ]
        let snapshot = SessionListFiltering.reconcileChoices(
            current: [], sessions: sessions, limit: 1
        )
        XCTAssertEqual(snapshot.map(\.path), ["/tmp/Alpha"])
        let outside = SessionListFiltering.option(for: "/tmp/Quiet", sessions: sessions)
        XCTAssertEqual(outside.path, "/tmp/Quiet")
        XCTAssertFalse(outside.label.isEmpty)
    }

    func testActiveIsTheActivityDotSetUnreadAloneIsNotActive() {
        func marked(_ key: String, _ marker: String, runtime: String = "codex") -> SessionSummary {
            SessionSummary(key: key, runtime: runtime, mtime: 1, hosted: marker == "recent", marker: marker)
        }
        let sessions = [
            marked("codex:wait", "waiting"),
            marked("claude:work", "working", runtime: "claude"),
            marked("codex:unread", "unread"),
            marked("codex:recent", "recent"),
            marked("codex:idle", ""),
            marked("codex:open", ""),
            marked("kimi:wait", "waiting", runtime: "kimi"),
            // Red unread overlay over a working activity behind it: still active.
            SessionSummary(key: "codex:dual", runtime: "codex", mtime: 1, attention: .working, marker: "unread"),
        ]
        // Pure red is only an unread explanation, not activity.
        XCTAssertFalse(SessionListFiltering.isActive(sessions[2]))
        XCTAssertTrue(SessionListFiltering.isActive(sessions[7]))
        XCTAssertEqual(
            SessionListFiltering.apply(sessions: sessions, runtimes: [], projects: [], activeOnly: true).map(\.key),
            ["codex:wait", "claude:work", "codex:recent", "codex:dual"]
        )
        XCTAssertEqual(
            SessionListFiltering.apply(sessions: sessions, runtimes: [.codex], projects: [], activeOnly: true,
                                       keeping: ["codex:open"]).map(\.key),
            ["codex:wait", "codex:recent", "codex:open", "codex:dual"]
        )
        XCTAssertEqual(SessionListFiltering.activeCount(sessions: sessions), 4)
        XCTAssertEqual(SessionListFiltering.activeCount(sessions: sessions, keeping: ["codex:open"]), 5)
        XCTAssertEqual(SessionListFiltering.apply(sessions: sessions, runtimes: [], projects: []).count, 7)
    }

    // MARK: - Helpers

    private func summary(
        key: String,
        title: String = "T",
        runtime: String? = nil,
        cwd: String = "/tmp/p",
        cwdDisplay: String? = nil,
        mtime: Double = 1_700_000_000,
        attention: String = "none"
    ) -> SessionSummary {
        // Tests run @MainActor; decoding never fails for these shapes.
        // swiftlint:disable:next force_try
        try! RemoteJSONDecoder.decode(
            SessionSummary.self,
            from: sessionDict(
                key: key,
                title: title,
                runtime: runtime,
                cwd: cwd,
                cwdDisplay: cwdDisplay ?? cwd,
                mtime: mtime,
                attention: attention
            )
        )
    }

    private func sessionDict(
        key: String,
        title: String,
        runtime: String?,
        cwd: String,
        cwdDisplay: String,
        mtime: Double,
        attention: String
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "key": key,
            "title": title,
            "cwd": cwd,
            "cwd_display": cwdDisplay,
            "mtime": mtime,
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
