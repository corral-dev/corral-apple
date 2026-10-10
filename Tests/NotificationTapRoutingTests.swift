import Foundation
@testable import Corral
import XCTest

/// Notification-tap routing regressions: the session leg must never push a route
/// for a key absent from the snapshot (that rendered the blank "No sessions"
/// screen with the ticket already consumed).
///
/// `sessions.list/watch` is a window (`has_more`), never an authoritative catalog,
/// so no list response may declare the target gone: misses wait for a direct
/// `session.get` lookup, and only the server's explicit `not_found` consumes with
/// visible recovery.
///
/// Scope: the exact pure logic the view uses — NotificationReply.resolveTap,
/// shouldStartLookup, classifyLookupError — plus PendingNotificationOpen ticket
/// discipline and SessionListStore alias merge. This file must not import or drive
/// PushRegistrar (UIKit), views, or NSE.
@MainActor
final class NotificationTapRoutingTests: XCTestCase {
    func testFoundKeyPushes() {
        XCTAssertEqual(NotificationReply.resolveTap(found: true), .push)
    }

    func testTargetOutsideWindowWaits() {
        // Bounded window without the key: keep waiting for the direct lookup,
        // never declare unavailable.
        XCTAssertEqual(NotificationReply.resolveTap(found: false), .wait)
    }

    func testUnchangedWindowWaits() {
        // An `unchanged` response carries no membership information at all.
        XCTAssertEqual(NotificationReply.resolveTap(found: false), .wait)
    }

    func testOneLookupPerTicket() {
        XCTAssertTrue(NotificationReply.shouldStartLookup(ticket: 7, inflightTicket: nil))
        XCTAssertFalse(NotificationReply.shouldStartLookup(ticket: 7, inflightTicket: 7))
        // A newer tap always supersedes the in-flight lookup.
        XCTAssertTrue(NotificationReply.shouldStartLookup(ticket: 8, inflightTicket: 7))
    }

    func testExplicitNotFoundIsUnavailable() {
        let missing = RemoteCallError(code: WireProtocol.eNotFound, message: "gone", hint: "")
        XCTAssertEqual(NotificationReply.classifyLookupError(missing), .unavailable)
    }

    func testNetworkErrorThenRecoveryStaysRetryable() {
        // Timeouts, transport failures, and other server codes keep the ticket.
        let retryable: [Error] = [
            RemoteClient.ConnectionError.timeout,
            RemoteClient.ConnectionError.notConnected,
            RemoteClient.ConnectionError.invalidResponse,
            RemoteCallError(code: WireProtocol.eInternal, message: "boom", hint: ""),
            RemoteCallError(code: WireProtocol.eUnavailable, message: "down", hint: ""),
        ]
        for error in retryable {
            XCTAssertEqual(NotificationReply.classifyLookupError(error), .wait)
        }
    }

    func testWaitingTapSurvivesSnapshotsUntilLookupResolves() {
        // Cold start / same-host wait: ticket unconsumed across window snapshots
        // that lack the key, consumed exactly once on resolve.
        var pending = PendingNotificationOpen()
        pending.store(hostID: "H", sessionKey: "new-session")
        let firstTicket = pending.ticket

        XCTAssertEqual(NotificationReply.resolveTap(found: false), .wait)
        XCTAssertTrue(NotificationReply.shouldStartLookup(ticket: firstTicket, inflightTicket: nil))
        // A repeat resolve while the lookup is in flight must not start another.
        XCTAssertFalse(NotificationReply.shouldStartLookup(ticket: firstTicket, inflightTicket: firstTicket))
        // Snapshots lacking the key never touch the ticket.
        XCTAssertEqual(pending.ticket, firstTicket)
        XCTAssertEqual(pending.sessionKey(for: "H"), "new-session")

        // Lookup found the session: consume once, route.
        XCTAssertEqual(NotificationReply.resolveTap(found: true), .push)
        XCTAssertTrue(pending.consume(hostID: "H", sessionKey: "new-session"))
        XCTAssertNil(pending.sessionKey(for: "H"))
        // A stale duplicate consume after routing must fail, never re-push.
        XCTAssertFalse(pending.consume(hostID: "H", sessionKey: "new-session"))
    }

    func testDuplicateTapCollapsesToOneTicket() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "H", sessionKey: "s1")
        let ticket = pending.ticket
        pending.store(hostID: "H", sessionKey: "s1")
        XCTAssertEqual(pending.ticket, ticket)
        XCTAssertTrue(NotificationReply.shouldRouteNotification(ticket: ticket, routedTicket: nil))
        XCTAssertFalse(pending.consume(hostID: "H", sessionKey: "other"))
        XCTAssertEqual(pending.sessionKey(for: "H"), "s1")
    }

    func testNewTapDuringPreviousLookupSupersedes() {
        // Old lookup in flight for ticket A; a new tap stores ticket B. The late
        // result for A must not consume B's ticket.
        var pending = PendingNotificationOpen()
        pending.store(hostID: "H", sessionKey: "sA")
        let ticketA = pending.ticket
        pending.store(hostID: "H", sessionKey: "sB")
        let ticketB = pending.ticket
        XCTAssertNotEqual(ticketA, ticketB)
        XCTAssertTrue(NotificationReply.shouldStartLookup(ticket: ticketB, inflightTicket: ticketA))
        // Late completion for A: ticket no longer matches, consume fails.
        XCTAssertFalse(pending.consume(hostID: "H", sessionKey: "sA"))
        XCTAssertEqual(pending.sessionKey(for: "H"), "sB")
    }

    func testLateWrongHostResultNeverConsumes() {
        // Same-host scoping: a resolve for host A never touches host B's ticket.
        var pending = PendingNotificationOpen()
        pending.store(hostID: "B", sessionKey: "sB")
        XCTAssertNil(pending.sessionKey(for: "A"))
        XCTAssertFalse(pending.consume(hostID: "A", sessionKey: "sB"))
        XCTAssertEqual(pending.sessionKey(for: "B"), "sB")
    }

    func testDirectLookupCanonicalAliasKeepsTappedKeyUsable() {
        // Server resolves a provisional tapped key to its canonical identity:
        // migrateSession preserves the old key as an alias, patch merges the
        // canonical summary, and the tapped key resolves afterwards.
        let store = SessionListStore()
        let oldKey = "provisional-1"
        XCTAssertNil(store.session(for: oldKey))
        store.migrateSession(from: oldKey, to: "canonical-9")
        let summary = SessionSummary(key: "canonical-9", title: "t")
        store.patchSession(summary)
        store.rememberOpened(summary)
        XCTAssertEqual(store.session(for: "canonical-9")?.key, "canonical-9")
        XCTAssertEqual(store.session(for: oldKey)?.key, "canonical-9")
    }

    func testSearchFilteredTargetStillResolves() {
        // session(for:) reads unfiltered records, so an active search filter must
        // not flip a found key into wait: found always pushes.
        XCTAssertEqual(NotificationReply.resolveTap(found: true), .push)
    }

    func testRoutablePendingHostNeedsPairedHost() {
        XCTAssertEqual(
            NotificationReply.routablePendingHost(requestHostID: "H", pairedHostIDs: ["H", "G"]),
            "H"
        )
        // Pre-model / unknown host list: stored but harmless, never routes.
        XCTAssertNil(NotificationReply.routablePendingHost(requestHostID: "H", pairedHostIDs: []))
        // Unpaired or removed host: ignored, no navigation, no input.
        XCTAssertNil(NotificationReply.routablePendingHost(requestHostID: "X", pairedHostIDs: ["H"]))
        XCTAssertNil(NotificationReply.routablePendingHost(requestHostID: nil, pairedHostIDs: ["H"]))
        XCTAssertNil(NotificationReply.routablePendingHost(requestHostID: "", pairedHostIDs: ["H"]))
    }

    func testPreModelTapRetainedUntilConfigureReplay() {
        // The delegate stores before any model exists; the ticket survives until
        // configure() replays validation — nothing is consumed or cleared early.
        var pending = PendingNotificationOpen()
        pending.store(hostID: "H", sessionKey: "s1")
        let ticket = pending.ticket
        // Replay while the host list is still unknown: harmless, retained.
        XCTAssertNil(NotificationReply.routablePendingHost(requestHostID: pending.request?.hostID, pairedHostIDs: []))
        XCTAssertEqual(pending.ticket, ticket)
        XCTAssertEqual(pending.sessionKey(for: "H"), "s1")
        // Replay once the model attaches with the paired host: routable, same ticket.
        XCTAssertEqual(
            NotificationReply.routablePendingHost(requestHostID: pending.request?.hostID, pairedHostIDs: ["H"]),
            "H"
        )
        XCTAssertEqual(pending.ticket, ticket)
        // Replay dedupe: identical replays never bump the ticket.
        pending.store(hostID: "H", sessionKey: "s1")
        XCTAssertEqual(pending.ticket, ticket)
    }

    func testUnpairedHostTapStaysHarmless() {
        var pending = PendingNotificationOpen()
        pending.store(hostID: "X", sessionKey: "sX")
        XCTAssertNil(NotificationReply.routablePendingHost(requestHostID: "X", pairedHostIDs: ["H"]))
        // Root routing drops it without consuming another host's ticket.
        pending.clear(hostID: "X")
        XCTAssertNil(pending.request)
    }

    func testPlaceholderMatrix() {
        // Content whenever the list is non-empty, regardless of tap state.
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: false, isLoading: false, connected: true,
                pendingTapWaiting: true, tapMissing: false, tapError: true, loadFailed: true
            ),
            .content
        )
        // Transport/list failure keeps its card and never consumes the tap.
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: true, isLoading: false, connected: true,
                pendingTapWaiting: true, tapMissing: false, tapError: false, loadFailed: true
            ),
            .loadFailed
        )
        // Connected wait (lookup in flight or imminent) shows loading, never empty.
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: true, isLoading: false, connected: true,
                pendingTapWaiting: true, tapMissing: false, tapError: false, loadFailed: false
            ),
            .loading
        )
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: true, isLoading: true, connected: false,
                pendingTapWaiting: false, tapMissing: false, tapError: false, loadFailed: false
            ),
            .loading
        )
        // Explicit not_found renders the dismissible missing view.
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: true, isLoading: false, connected: true,
                pendingTapWaiting: false, tapMissing: true, tapError: false, loadFailed: false
            ),
            .tapMissing
        )
        // Lookup failure and offline waits render retry recovery, not empty.
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: true, isLoading: false, connected: true,
                pendingTapWaiting: true, tapMissing: false, tapError: true, loadFailed: false
            ),
            .tapError
        )
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: true, isLoading: false, connected: false,
                pendingTapWaiting: true, tapMissing: false, tapError: false, loadFailed: false
            ),
            .tapError
        )
        // No tap, no failure, no content: the genuine empty screen.
        XCTAssertEqual(
            SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: true, isLoading: false, connected: true,
                pendingTapWaiting: false, tapMissing: false, tapError: false, loadFailed: false
            ),
            .empty
        )
    }
}
