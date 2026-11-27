import Foundation
import os
#if os(iOS)
import SwiftUI
import UIKit
#endif
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

    func testDefaultModeDefaultsToChatAndPersistsAcrossReloads() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertEqual(store.defaultMode, .chat)

        let observationCount = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = store.defaultMode
        } onChange: {
            observationCount.withLock { $0 += 1 }
        }

        store.defaultMode = .terminal
        XCTAssertEqual(observationCount.withLock { $0 }, 1)
        XCTAssertEqual(store.defaultMode, .terminal)

        let reloadedTerminal = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertEqual(reloadedTerminal.defaultMode, .terminal)

        reloadedTerminal.defaultMode = .chat
        let reloadedChat = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertEqual(reloadedChat.defaultMode, .chat)
    }

    func testDefaultModeRespectsNonPersistingGuard() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: false)
        store.defaultMode = .terminal
        XCTAssertEqual(store.defaultMode, .terminal)

        let reloaded = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertEqual(reloaded.defaultMode, .chat)
    }

    func testAdoptDefaultModeMatchesMacRules() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)

        // Default `.chat` leaves unseen sessions unrecorded so a later switch to
        // `.terminal` still applies on first open under that preference.
        XCTAssertEqual(store.adoptDefaultModeIfUnset(for: "claude:deferred", hostID: "host-a"), .chat)
        XCTAssertNil(store.mode(for: "claude:deferred", hostID: "host-a"))

        store.defaultMode = .terminal
        XCTAssertEqual(store.adoptDefaultModeIfUnset(for: "claude:deferred", hostID: "host-a"), .terminal)
        XCTAssertEqual(store.mode(for: "claude:deferred", hostID: "host-a"), .terminal)

        // Sessions running in another terminal window stay in Chat View and write nothing.
        XCTAssertEqual(
            store.adoptDefaultModeIfUnset(for: "codex:elsewhere", hostID: "host-a", runsElsewhere: true),
            .chat
        )
        XCTAssertNil(store.mode(for: "codex:elsewhere", hostID: "host-a"))

        // Explicit Chat choice always wins over the Terminal default.
        store.setMode(.chat, for: "pi:explicit-chat", hostID: "host-a")
        XCTAssertEqual(store.adoptDefaultModeIfUnset(for: "pi:explicit-chat", hostID: "host-a"), .chat)
        XCTAssertEqual(store.mode(for: "pi:explicit-chat", hostID: "host-a"), .chat)

        // Switching an adopted session back to Chat persists and is not overridden on reopen.
        store.setMode(.chat, for: "claude:deferred", hostID: "host-a")
        XCTAssertEqual(store.adoptDefaultModeIfUnset(for: "claude:deferred", hostID: "host-a"), .chat)
    }

    func testApplyDefaultModeForCreatedSessionAndPromotion() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)

        XCTAssertEqual(store.applyDefaultModeForCreatedSession(sessionKey: "pending:chat", hostID: "host-a"), .chat)
        XCTAssertNil(store.mode(for: "pending:chat", hostID: "host-a"))

        store.defaultMode = .terminal
        XCTAssertEqual(store.applyDefaultModeForCreatedSession(sessionKey: "pending:term", hostID: "host-a"), .terminal)
        XCTAssertEqual(store.mode(for: "pending:term", hostID: "host-a"), .terminal)

        store.promote(oldKey: "pending:term", to: "claude:canon", hostID: "host-a")
        let reloaded = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertNil(reloaded.mode(for: "pending:term", hostID: "host-a"))
        XCTAssertEqual(reloaded.mode(for: "claude:canon", hostID: "host-a"), .terminal)
    }

    func testEffectiveOpenModeReflectsStoredChoiceDefaultAndRunsElsewhere() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.defaultMode = .terminal

        XCTAssertEqual(store.effectiveOpenMode(for: "unseen", hostID: "host-a"), .terminal)
        XCTAssertEqual(store.effectiveOpenMode(for: "unseen", hostID: "host-a", runsElsewhere: true), .chat)
        // Reconnect stability: effectiveMode remains .chat when no per-session choice is stored.
        XCTAssertEqual(store.effectiveMode(for: "unseen", hostID: "host-a"), .chat)

        store.setMode(.chat, for: "explicit-chat", hostID: "host-a")
        XCTAssertEqual(store.effectiveOpenMode(for: "explicit-chat", hostID: "host-a"), .chat)

        store.defaultMode = .chat
        store.setMode(.terminal, for: "explicit-terminal", hostID: "host-a")
        XCTAssertEqual(store.effectiveOpenMode(for: "explicit-terminal", hostID: "host-a"), .terminal)
    }

    func testRemoveAndRemoveAllDoNotResetDefaultMode() {
        let defaults = makeDefaults()
        let store = SessionDetailModeStore(defaults: defaults, persists: true)
        store.defaultMode = .terminal
        store.setMode(.terminal, for: "claude:s1", hostID: "host-a")

        store.remove(sessionKey: "claude:s1", hostID: "host-a")
        store.removeAll(hostID: "host-a")

        let reloaded = SessionDetailModeStore(defaults: defaults, persists: true)
        XCTAssertEqual(reloaded.defaultMode, .terminal)
        XCTAssertNil(reloaded.mode(for: "claude:s1", hostID: "host-a"))
    }

    #if os(iOS)
    func testHostSettingsDisplaySectionRendersDefaultOpenMode() async throws {
        let savedDefault = UserDefaults.standard.object(forKey: SessionDetailModeStore.defaultModeKey)
        let savedSharedMode = SessionDetailModeStore.shared.defaultMode
        defer {
            SessionDetailModeStore.shared.defaultMode = savedSharedMode
            if let savedDefault {
                UserDefaults.standard.set(savedDefault, forKey: SessionDetailModeStore.defaultModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SessionDetailModeStore.defaultModeKey)
            }
        }

        let model = AppModel()
        let hostInfo = HostInfo(
            hostID: "fixture-host",
            name: "the paired Mac",
            publicKeyHex: "0123456789abcdef",
            relayURL: nil,
            localHints: [],
            pairedAt: Date()
        )
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = try XCTUnwrap(scenes.first)

        for (name, mode, dark, localeID) in [
            ("light-en", SessionDetailMode.chat, false, "en"),
            ("dark-zh", SessionDetailMode.terminal, true, "zh-Hans"),
        ] {
            let image = try await renderHostSettingsSnapshot(
                windowScene: windowScene,
                model: model,
                hostInfo: hostInfo,
                mode: mode,
                dark: dark,
                localeID: localeID
            )
            let attachment = XCTAttachment(image: image)
            attachment.name = "host-settings-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            if let data = image.pngData() {
                let out = URL(fileURLWithPath: "/tmp/corral-host-settings-\(name).png")
                try? data.write(to: out, options: .atomic)
            }
        }
    }

    private func renderHostSettingsSnapshot(
        windowScene: UIWindowScene,
        model: AppModel,
        hostInfo: HostInfo,
        mode: SessionDetailMode,
        dark: Bool,
        localeID: String
    ) async throws -> UIImage {
        SessionDetailModeStore.shared.defaultMode = mode
        let root = NavigationStack {
            HostSettingsView(host: hostInfo)
        }
        .environment(model)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: localeID))

        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.frame = window.bounds
        for _ in 0..<25 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        return UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
    #endif
}
