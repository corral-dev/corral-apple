import Foundation
import Observation
@testable import Corral
import XCTest

/// Xcode-only: drives the real `AppModel`, which requires the Apple runtime
/// (HostStore, UserDefaults, NWPathMonitor). Excluded from the portable manifest.
/// No network is performed; selection is in-memory only.
@MainActor
final class AppModelIdentityTests: XCTestCase {
    func testSelectingHostNeverRelabelsConnection() {
        let model = AppModel()
        XCTAssertNil(model.connectedHostID)
        let other = HostInfo(hostID: "host-b", name: "B", publicKeyHex: String(repeating: "0", count: 64))
        model.selectHost(other)
        XCTAssertNil(model.connectedHostID, "selecting must not relabel the connection")
        XCTAssertFalse(model.isConnected(to: other))
    }

#if DEBUG
    /// True regression for the relabel bug: the watcher must publish the host
    /// captured at observe time (A), even when the selection moved to B before
    /// the captured client turned ready. The old
    /// `connectedHostID = selectedHostID` line would publish B and fail here.
    func testWatcherKeepsCapturedHostWhenSelectionChanges() async throws {
        let defaults = UserDefaults.standard
        let preferKey = "corral.preferDirect"
        let sizeKey = SessionTextSize.storageKey
        let savedPrefer = defaults.object(forKey: preferKey)
        let savedSize = defaults.object(forKey: sizeKey)
        defer {
            if let savedPrefer {
                defaults.set(savedPrefer, forKey: preferKey)
            } else {
                defaults.removeObject(forKey: preferKey)
            }
            if let savedSize {
                defaults.set(savedSize, forKey: sizeKey)
            } else {
                defaults.removeObject(forKey: sizeKey)
            }
        }

        let model = AppModel()
        let client = RemoteClient(devicePrivateKey: Data(repeating: 9, count: 32))
        defer { client.disconnect() }
        model.observeConnectionForTesting(client, hostID: "host-a")

        // Selection moves to B while A's connection is still settling.
        model.selectHost(
            HostInfo(hostID: "host-b", name: "B", publicKeyHex: String(repeating: "1", count: 64))
        )

        // The captured client turns ready; the real watcher (200 ms cadence)
        // must publish A, never the current selection B.
        client.controlConfirmed = true
        client.setConnectionStateForTesting(.ready)
        let deadline = Date().addingTimeInterval(5)
        while model.connectedHostID == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.connectedHostID, "host-a")
    }

    func testSteadyReadyWatcherEmitsZeroObservationInvalidationsAndRespectsGrace() async throws {
        let model = AppModel()
        let client = RemoteClient(devicePrivateKey: Data(repeating: 1, count: 32))
        defer {
            model.disconnect()
            client.disconnect()
        }
        client.setConnectionStateForTesting(.ready)
        client.controlConfirmed = true
        client.activeTransport = .local
        model.observeConnectionForTesting(client, hostID: "host-steady")
        XCTAssertEqual(model.connectionState, .connected)

        let invalidations = ObservationCounter()
        withObservationTracking {
            _ = model.connectionState
            _ = model.activeTransport
            _ = model.connectedHostID
            _ = model.connectedAccess
            _ = model.connectedRuntimes
        } onChange: {
            invalidations.increment()
        }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(invalidations.value, 0)

        client.setConnectionStateForTesting(.ready)
        client.controlConfirmed = true
        client.activeTransport = .local
        XCTAssertEqual(invalidations.value, 0)

        client.controlConfirmed = false
        client.setConnectionStateForTesting(.reconnecting)
        XCTAssertEqual(model.connectionState, .connected)
        try await Task.sleep(for: .seconds(TransientDropPolicy.presentationGrace + 0.15))
        XCTAssertEqual(model.connectionState, .reconnecting)
        XCTAssertGreaterThan(invalidations.value, 0)
    }
#endif
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
