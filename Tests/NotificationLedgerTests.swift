import XCTest
@testable import Corral

@MainActor final class NotificationLedgerTests: XCTestCase {
    func testDistinctRoundsAndHostsAndKinds() {
        let first = SessionSummary(key: "codex:s", runtime: "codex", mtime: 10, completionID: "turn-1")
        let second = SessionSummary(key: "codex:s", runtime: "codex", mtime: 11, completionID: "turn-2")
        let id = SessionNotificationKind.completed.identity(hostID: "a", session: first)!
        XCTAssertNotEqual(id, SessionNotificationKind.completed.identity(hostID: "a", session: second))
        XCTAssertNotEqual(id, SessionNotificationKind.completed.identity(hostID: "b", session: first))
        XCTAssertNotEqual(id, SessionNotificationKind.aborted.identity(hostID: "a", session: first))
        XCTAssertNotEqual(id, SessionNotificationKind.transient.identity(hostID: "a", session: first))
        var ledger = NotificationLedger()
        XCTAssertFalse(ledger.contains(id))
        ledger.record(id)
        XCTAssertTrue(ledger.contains(id))
    }

    func testMetadataChangesAndRestartKeepIdentity() throws {
        let first = SessionSummary(key: "codex:s", runtime: "codex", title: "old", mtime: 10, completionID: "turn-1")
        let changed = SessionSummary(key: "codex:s", runtime: "codex", title: "new", mtime: 99, lastAgent: "new preview", completionID: "turn-1")
        let id = SessionNotificationKind.completed.identity(hostID: "a", session: first)!
        XCTAssertEqual(id, SessionNotificationKind.completed.identity(hostID: "a", session: changed))
        var ledger = NotificationLedger()
        ledger.record(id)
        let restored = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertTrue(restored.contains(id))
    }

    func testWeakCompletionAndDormantRuntimeCannotNotify() {
        XCTAssertNil(SessionNotificationKind.completed.identity(hostID: "a", session: SessionSummary(key: "codex:s", runtime: "codex")))
        XCTAssertNil(SessionNotificationKind.waiting.identity(hostID: "a", session: SessionSummary(key: "kimi:s", runtime: "kimi")))
        XCTAssertNil(SessionNotificationKind.waiting.identity(hostID: "", session: SessionSummary(key: "codex:s", runtime: "codex")))
    }

    func testWaitingRoundsAndKeyPromotion() throws {
        let first = SessionSummary(key: "pi:s", runtime: "pi", mtime: 10, completionID: "stable")
        let second = SessionSummary(key: "pi:s", runtime: "pi", mtime: 11, completionID: "stable")
        XCTAssertNotEqual(SessionNotificationKind.waiting.identity(hostID: "a", session: first),
                          SessionNotificationKind.waiting.identity(hostID: "a", session: second))
        XCTAssertEqual(first.replacingKey("pi:canonical").completionID, "stable")
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: Data(#"{"key":"pi:s","runtime":"pi","completion_id":"native-final"}"#.utf8))
        XCTAssertEqual(decoded.completionID, "native-final")
    }

    func testPreferencesDefaultOnAndPersistDisabledChoice() {
        let name = "CorralNotificationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CompletionNotificationPreferences(defaults: defaults)
        XCTAssertTrue(preferences.completed)
        XCTAssertTrue(preferences.aborted)
        XCTAssertFalse(preferences.transient)
        preferences.completed = false
        preferences.transient = true
        let restored = CompletionNotificationPreferences(defaults: defaults)
        XCTAssertFalse(restored.completed)
        XCTAssertTrue(restored.aborted)
        XCTAssertTrue(restored.transient)
    }
}
