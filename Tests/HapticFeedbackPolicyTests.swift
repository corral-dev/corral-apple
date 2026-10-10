import XCTest
@testable import Corral

final class HapticFeedbackPolicyTests: XCTestCase {
    func testTimeoutIsWarningAndCancellationIsQuiet() {
        XCTAssertEqual(HapticEvent.failure(for: RemoteClient.ConnectionError.timeout), .warning)
        XCTAssertEqual(HapticEvent.failure(for: RemoteCallError(code: "rejected", message: "Rejected", hint: "")), .error)
        XCTAssertEqual(HapticEvent.failure(for: PairingParseError.invalidURL), .error)
        XCTAssertNil(HapticEvent.failure(for: CancellationError()))
        XCTAssertNil(HapticEvent.failure(for: URLError(.cancelled)))
    }
    @MainActor
    func testReturningToScreenDoesNotReviveOldOperation() {
        let scope = HapticScope()
        scope.activate()
        let old = scope.beginOperation()
        XCTAssertTrue(scope.allows(old))
        scope.deactivate()
        scope.activate()
        XCTAssertFalse(scope.allows(old))
        XCTAssertTrue(scope.allows(scope.beginOperation()))
    }
    func testBackgroundOrAbandonedResultsNeverReplay() {
        for reason in 0..<2 {
            var policy = HapticFeedbackPolicy()
            let id = UUID()
            XCTAssertFalse(policy.consume(.success, operationID: id,
                isActive: reason != 0, isVisible: reason != 1, now: 1))
            XCTAssertFalse(policy.consume(.success, operationID: id,
                isActive: true, isVisible: true, now: 2))
        }
    }

    func testBatchCanStartOnceAndWarnOnceThenConfirmSuccess() {
        var policy = HapticFeedbackPolicy()
        let id = UUID()
        func consume(_ event: HapticEvent) -> Bool {
            policy.consume(event, operationID: id,
                isActive: true, isVisible: true, now: 1)
        }
        XCTAssertTrue(consume(.committed))
        XCTAssertFalse(consume(.committed))
        XCTAssertTrue(consume(.warning))
        XCTAssertFalse(consume(.error))
        XCTAssertTrue(consume(.success))
        XCTAssertFalse(consume(.success))
    }

    func testSelectionThrottleDoesNotSuppressIndependentFailure() {
        var policy = HapticFeedbackPolicy()
        func consume(_ event: HapticEvent, _ now: Double) -> Bool {
            policy.consume(event, operationID: UUID(),
                isActive: true, isVisible: true, now: now)
        }
        XCTAssertTrue(consume(.selection, 1))
        XCTAssertFalse(consume(.selection, 1.1))
        XCTAssertTrue(consume(.error, 1.1))
        XCTAssertTrue(consume(.selection, 1.2))
    }
}
