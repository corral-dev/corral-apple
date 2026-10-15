import Foundation
@testable import Corral
import XCTest

/// Pairing host-ID authority + RPC cancellation (review fixes).
@MainActor
final class PairingCancellationTests: XCTestCase {
    private func makeKey() throws -> (Data, String) {
        let privateKey = RemoteCryptoKeys.generatePrivateKey()
        let publicKey = try RemoteCryptoKeys.publicKey(from: privateKey)
        let hostID = try RemoteCryptoKeys.routingID(fromX25519: publicKey)
        return (publicKey, hostID)
    }

    private func pairURL(publicKey: Data, hostID: String?, name: String = "dev") -> URL {
        let key = PairingPayload.encodePublicKeyBase64URL(publicKey)
        var items = "v=2&n=\(name)&k=\(key)&c=code123"
        if let hostID { items += "&h=\(hostID)" }
        return URL(string: "corral://pair?\(items)")!
    }

    func testParseDerivesHostIDWithoutH() throws {
        let (publicKey, derived) = try makeKey()
        let payload = try PairingPayload.parse(url: pairURL(publicKey: publicKey, hostID: nil))
        XCTAssertEqual(payload.hostID, derived)
    }

    func testParseAcceptsMatchingHRejectsMismatch() throws {
        let (publicKey, derived) = try makeKey()
        let matching = try PairingPayload.parse(url: pairURL(publicKey: publicKey, hostID: derived))
        XCTAssertEqual(matching.hostID, derived)
        XCTAssertThrowsError(try PairingPayload.parse(url: pairURL(publicKey: publicKey, hostID: "wrong-host-id"))) { error in
            guard let error = error as? PairingParseError, case .hostIDMismatch = error else {
                return XCTFail("Expected host identity mismatch")
            }
        }
    }

    func testCodableRoundTripRejectsTamperedH() throws {
        let (publicKey, derived) = try makeKey()
        let payload = try PairingPayload.parse(url: pairURL(publicKey: publicKey, hostID: derived))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(PairingPayload.self, from: data)
        XCTAssertEqual(decoded, payload)

        var tampered = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        tampered["h"] = "tampered-host"
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)
        XCTAssertThrowsError(try JSONDecoder().decode(PairingPayload.self, from: tamperedData)) { error in
            XCTAssertTrue(error is PairingParseError)
        }
    }

    /// A cancelled RPC must leave no pending request behind (no 20s-timeout leak).
    func testCancelledCallRawCleansUpPending() async throws {
        let client = RemoteClient(devicePrivateKey: RemoteCryptoKeys.generatePrivateKey())
        defer { client.disconnect() }
        client.setConnectionStateForTesting(.ready)
        _ = client.installPlaneForTesting(isControl: true)
        let task = Task { _ = try await client.callRaw("session.messages", params: [:], timeout: 30) }
        // Let the request register, then cancel: with the fix this throws
        // CancellationError immediately instead of lingering to the timeout.
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled call should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertTrue(client.pendingRequests.isEmpty)
    }
}
