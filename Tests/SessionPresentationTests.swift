import Foundation
import XCTest
@testable import Corral

@MainActor
final class SessionPresentationTests: XCTestCase {
    func testTitleIconKeepsCompleteEmojiGraphemes() {
        for icon in ["🔍", "⚙️", "👩🏽‍💻", "🇨🇳", "1️⃣", "❤️"] {
            XCTAssertEqual(SessionPresentation.titleIcon(in: "Project \(icon) investigation 🛠️"), icon)
        }
    }

    func testTitleIconDoesNotInventIdentityFromTextOrDigits() {
        for title in ["", "  ", "Fix Corral 123", "#1 * task", "普通会话", "e\u{301}"] {
            XCTAssertNil(SessionPresentation.titleIcon(in: title))
        }
    }

    func testTitleIconReflectsRenameAndRemoval() {
        XCTAssertEqual(SessionPresentation.titleIcon(in: "🔍 Inspect"), "🔍")
        XCTAssertEqual(SessionPresentation.titleIcon(in: "🛠️ Repair"), "🛠️")
        XCTAssertNil(SessionPresentation.titleIcon(in: "Repair"))
    }

    func testRelativeTimeJustNowWithinThreeMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let label = SessionPresentation.relativeTimeLabel(
            mtime: now.timeIntervalSince1970 - 120,
            now: now
        )
        XCTAssertEqual(label, String(localized: "sessions.time.just_now"))
    }

    func testRelativeTimeMinutesAndHours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let minutes = SessionPresentation.relativeTimeLabel(
            mtime: now.timeIntervalSince1970 - (12 * 60),
            now: now
        )
        XCTAssertEqual(minutes, String(localized: "sessions.time.minutes_ago \(12)"))

        let hours = SessionPresentation.relativeTimeLabel(
            mtime: now.timeIntervalSince1970 - (5 * 3600),
            now: now
        )
        XCTAssertEqual(hours, String(localized: "sessions.time.hours_ago \(5)"))
    }

    func testRelativeTimeFallsBackToAbsoluteAfterOneDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mtime = now.timeIntervalSince1970 - (2 * 86_400)
        let label = SessionPresentation.relativeTimeLabel(mtime: mtime, now: now)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        XCTAssertEqual(label, formatter.string(from: Date(timeIntervalSince1970: mtime)))
    }

    func testFutureClockSkewCountsAsJustNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let label = SessionPresentation.relativeTimeLabel(
            mtime: now.timeIntervalSince1970 + 30,
            now: now
        )
        XCTAssertEqual(label, String(localized: "sessions.time.just_now"))
    }

    func testProjectNamePrefersLastSegment() {
        XCTAssertEqual(SessionPresentation.projectName(cwd: "~/Codes/Corral"), "Corral")
        XCTAssertEqual(SessionPresentation.projectName(cwd: "/tmp/p"), "p")
    }

    func testProjectNameKeepsParentForAmbiguousLeaf() {
        XCTAssertEqual(
            SessionPresentation.projectName(cwd: "~/Codes/Corral/ios"),
            "Corral / ios"
        )
        XCTAssertEqual(
            SessionPresentation.projectName(cwd: "~/Codes/Corral/cli"),
            "Corral / cli"
        )
    }

    func testProjectNameHomeAndEmpty() {
        XCTAssertEqual(SessionPresentation.projectName(cwd: "~"), "~")
        XCTAssertEqual(SessionPresentation.projectName(cwd: ""), "")
    }

    func testDisambiguationExpandsOnlyDuplicates() {
        let labels = SessionPresentation.disambiguationSuffixes(pathsByKey: [
            "a": "~/Codes/Corral/ios",
            "b": "~/Codes/Other/ios",
            "c": "~/Codes/Corral",
        ])
        XCTAssertEqual(labels["a"], "Corral / ios")
        XCTAssertEqual(labels["b"], "Other / ios")
        XCTAssertEqual(labels["c"], "Corral")
    }

    func testStatusMarkerFollowsHostMarkerNotLiveness() throws {
        let idleLive = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "claude:a", "live": true, "hosted": true, "attention": "none", "marker": "",
        ])
        XCTAssertNil(SessionPresentation.statusMarker(for: idleLive), "a live but idle process gets no dot")
        let recent = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "claude:b", "live": true, "attention": "none", "marker": "recent",
        ])
        XCTAssertEqual(SessionPresentation.statusMarker(for: recent), .recent)
        let working = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "claude:c", "attention": "working", "marker": "working",
        ])
        XCTAssertEqual(SessionPresentation.statusMarker(for: working), .working)
    }

    func testStatusMarkerFallsBackToAttentionForOlderHosts() throws {
        let old = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "claude:d", "live": true, "attention": "none",
        ])
        XCTAssertNil(old.marker)
        XCTAssertNil(SessionPresentation.statusMarker(for: old))
        let waiting = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "claude:e", "attention": "waiting",
        ])
        XCTAssertEqual(SessionPresentation.statusMarker(for: waiting), .waiting)
    }

    func testUnreadIsIndependentOverlayOverActivity() {
        // Red over green behind it: both stay visible, activity preserved.
        let dual = SessionSummary(key: "codex:d", attention: .working, marker: "unread")
        XCTAssertTrue(SessionPresentation.hasUnread(for: dual))
        XCTAssertEqual(SessionPresentation.activityMarker(for: dual), .working)
        // Pure red: no activity (red alone is not active).
        let red = SessionSummary(key: "codex:r", attention: .unread, marker: "unread")
        XCTAssertTrue(SessionPresentation.hasUnread(for: red))
        XCTAssertNil(SessionPresentation.activityMarker(for: red))
        // Locally cleared red (marker "") keeps the green behind it.
        let cleared = SessionSummary(key: "codex:c", attention: .working, marker: "")
        XCTAssertFalse(SessionPresentation.hasUnread(for: cleared))
        XCTAssertEqual(SessionPresentation.activityMarker(for: cleared), .working)
        // Yellow behind red, and pure yellow.
        let waitDual = SessionSummary(key: "codex:w", attention: .waiting, marker: "unread")
        XCTAssertTrue(SessionPresentation.hasUnread(for: waitDual))
        XCTAssertEqual(SessionPresentation.activityMarker(for: waitDual), .waiting)
        let wait = SessionSummary(key: "codex:y", attention: .waiting, marker: "waiting")
        XCTAssertFalse(SessionPresentation.hasUnread(for: wait))
        XCTAssertEqual(SessionPresentation.activityMarker(for: wait), .waiting)
    }

    func testPreviewFollowsLatestSpeakerAndPreservesFallback() throws {
        let userNewer = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "antigravity:a",
            "last_user": "最新的用户追问",
            "last_agent": "更早的助手回复",
            "last_msg_role": "user",
        ])
        XCTAssertEqual(SessionPresentation.preview(for: userNewer), "最新的用户追问")

        let agentNewer = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "antigravity:b",
            "last_user": "用户问题",
            "last_agent": "最新的助手回复",
            "last_msg_role": "assistant",
        ])
        XCTAssertEqual(SessionPresentation.preview(for: agentNewer), "最新的助手回复")

        let userRoleWithEmptyUser = SessionSummary(
            key: "antigravity:c", lastUser: "", lastAgent: "回退助手", lastMessageRole: "user"
        )
        XCTAssertEqual(SessionPresentation.preview(for: userRoleWithEmptyUser), "回退助手")

        let agentRoleWithEmptyAgent = SessionSummary(
            key: "antigravity:d", lastUser: "回退用户", lastAgent: "", lastMessageRole: "assistant"
        )
        XCTAssertEqual(SessionPresentation.preview(for: agentRoleWithEmptyAgent), "回退用户")

        let legacyHost = try RemoteJSONDecoder.decode(SessionSummary.self, from: [
            "key": "claude:e",
            "last_user": "旧宿主用户",
            "last_agent": "旧宿主助手",
        ])
        XCTAssertNil(legacyHost.lastMessageRole)
        XCTAssertEqual(SessionPresentation.preview(for: legacyHost), "旧宿主助手")

        let migrated = userNewer.replacingKey("antigravity:a-canonical")
        XCTAssertEqual(migrated.lastMessageRole, "user")

        let store = SessionListStore()
        let unreadUser = SessionSummary(
            key: "pi:u", attention: .unread, lastUser: "新提问", lastAgent: "旧回答",
            lastMessageRole: "user", marker: "unread"
        )
        store.updateSessions([unreadUser])
        store.markReadLocally(key: "pi:u")
        XCTAssertEqual(store.session(for: "pi:u")?.lastMessageRole, "user")
        XCTAssertEqual(SessionPresentation.preview(for: store.session(for: "pi:u")!), "新提问")
    }
}
