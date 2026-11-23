import Foundation
@testable import Corral
import XCTest

@MainActor
final class SessionDetailModeStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.x0c.corral.tests.detail-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testUnseenSessionDefaultsToNilAndEffectiveChat() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(store.mode(for: "claude:s1", hostID: "host-a"))
        XCTAssertEqual(store.effectiveMode(for: "claude:s1", hostID: "host-a"), .chat)
    }

    func testModePersistsAcrossReloadsForBothTerminalAndChat() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.setMode(.terminal, for: "claude:s1", hostID: "host-a")

        let relaunchedTerminal = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertEqual(relaunchedTerminal.mode(for: "claude:s1", hostID: "host-a"), .terminal)
        XCTAssertEqual(relaunchedTerminal.effectiveMode(for: "claude:s1", hostID: "host-a"), .terminal)

        relaunchedTerminal.setMode(.chat, for: "claude:s1", hostID: "host-a")
        let relaunchedChat = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertEqual(relaunchedChat.mode(for: "claude:s1", hostID: "host-a"), .chat)
        XCTAssertEqual(relaunchedChat.effectiveMode(for: "claude:s1", hostID: "host-a"), .chat)
    }

    func testHostIsolationAndRemoveAllOnlyClearsTargetHost() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.setMode(.terminal, for: "claude:shared", hostID: "host-a")
        store.setMode(.chat, for: "claude:shared", hostID: "host-b")

        XCTAssertEqual(store.mode(for: "claude:shared", hostID: "host-a"), .terminal)
        XCTAssertEqual(store.mode(for: "claude:shared", hostID: "host-b"), .chat)

        store.removeAll(hostID: "host-a")

        let reloaded = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(reloaded.mode(for: "claude:shared", hostID: "host-a"))
        XCTAssertEqual(reloaded.mode(for: "claude:shared", hostID: "host-b"), .chat)
    }

    func testRemoveSingleSessionPersistsRemoval() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.setMode(.terminal, for: "claude:s1", hostID: "host-a")
        store.setMode(.terminal, for: "claude:s2", hostID: "host-a")

        store.remove(sessionKey: "claude:s1", hostID: "host-a")

        let reloaded = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(reloaded.mode(for: "claude:s1", hostID: "host-a"))
        XCTAssertEqual(reloaded.mode(for: "claude:s2", hostID: "host-a"), .terminal)
    }

    func testLRUEvictionPrefersOtherHostsThenOldestInCurrentHost() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true, limit: 2)
        store.setMode(.terminal, for: "s1", hostID: "host-a")
        store.setMode(.terminal, for: "s-other", hostID: "host-b")
        // Writing to host-a evicts host-b before host-a's earlier entry.
        store.setMode(.chat, for: "s2", hostID: "host-a")

        let afterCrossHostWrite = SessionDetailModeStore(defaults: defaults, persists: true, limit: 2)
        XCTAssertNil(afterCrossHostWrite.mode(for: "s-other", hostID: "host-b"))
        XCTAssertEqual(afterCrossHostWrite.mode(for: "s1", hostID: "host-a"), .terminal)
        XCTAssertEqual(afterCrossHostWrite.mode(for: "s2", hostID: "host-a"), .chat)

        // Third entry on host-a evicts s1 (oldest in host-a).
        afterCrossHostWrite.setMode(.terminal, for: "s3", hostID: "host-a")
        let afterSameHostEviction = SessionDetailModeStore(defaults: defaults, persists: true, limit: 2)
        XCTAssertNil(afterSameHostEviction.mode(for: "s1", hostID: "host-a"))
        XCTAssertEqual(afterSameHostEviction.mode(for: "s2", hostID: "host-a"), .chat)
        XCTAssertEqual(afterSameHostEviction.mode(for: "s3", hostID: "host-a"), .terminal)
    }

    func testPromotePreservesProvisionalModeWithoutOverwritingExplicitCanonicalChoice() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.setMode(.terminal, for: "pending:1", hostID: "host-a")
        store.promote(oldKey: "pending:1", to: "claude:real-1", hostID: "host-a")

        let promoted = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(promoted.mode(for: "pending:1", hostID: "host-a"))
        XCTAssertEqual(promoted.mode(for: "claude:real-1", hostID: "host-a"), .terminal)

        // Explicit canonical choice must not be overwritten by a late alias promotion.
        promoted.setMode(.terminal, for: "pending:2", hostID: "host-a")
        promoted.setMode(.chat, for: "claude:real-2", hostID: "host-a")
        promoted.promote(oldKey: "pending:2", to: "claude:real-2", hostID: "host-a")

        let preserved = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(preserved.mode(for: "pending:2", hostID: "host-a"))
        XCTAssertEqual(preserved.mode(for: "claude:real-2", hostID: "host-a"), .chat)
    }

    func testReconcileAliasesPromotesMostRecentAliasWhenCanonicalUnset() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.setMode(.chat, for: "pending:older", hostID: "host-a")
        store.setMode(.terminal, for: "pending:newer", hostID: "host-a")

        let aliases = [
            "pending:older": "codex:canon",
            "pending:newer": "codex:canon",
        ]
        store.reconcileAliases(hostID: "host-a") { aliases[$0] ?? $0 }

        let reloaded = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(reloaded.mode(for: "pending:older", hostID: "host-a"))
        XCTAssertNil(reloaded.mode(for: "pending:newer", hostID: "host-a"))
        XCTAssertEqual(reloaded.mode(for: "codex:canon", hostID: "host-a"), .terminal)
    }

    func testNonPersistingStoreUpdatesInMemoryWithoutWritingDefaults() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: false)
        store.setMode(.terminal, for: "claude:s1", hostID: "host-a")
        XCTAssertEqual(store.mode(for: "claude:s1", hostID: "host-a"), .terminal)

        let reloaded = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(reloaded.mode(for: "claude:s1", hostID: "host-a"))
    }

    func testEmptyHostOrSessionKeyIsIgnored() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.setMode(.terminal, for: "", hostID: "host-a")
        store.setMode(.terminal, for: "claude:s1", hostID: "")
        XCTAssertNil(store.mode(for: "", hostID: "host-a"))
        XCTAssertNil(store.mode(for: "claude:s1", hostID: ""))
        XCTAssertEqual(store.effectiveMode(for: "", hostID: "host-a"), .chat)
    }
}
