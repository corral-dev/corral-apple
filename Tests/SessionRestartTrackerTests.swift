import Foundation
@testable import Corral
import XCTest

@MainActor
final class SessionRestartTrackerTests: XCTestCase {
    func testBeginIsImmediateAndRejectsDuplicateTaps() {
        let tracker = SessionRestartTracker()
        XCTAssertTrue(tracker.begin("codex:a"))
        XCTAssertEqual(tracker.phase(for: "codex:a"), .restarting)
        XCTAssertFalse(tracker.begin("codex:a"))
        XCTAssertNil(tracker.phase(for: "codex:b"))
    }

    func testFailureClearsAtOnce() {
        let tracker = SessionRestartTracker()
        tracker.begin("codex:a")
        tracker.finish("codex:a", succeeded: false)
        XCTAssertNil(tracker.phase(for: "codex:a"))
    }

    func testSuccessConfirmsBrieflyThenClears() async throws {
        let tracker = SessionRestartTracker(confirmationDuration: .milliseconds(50))
        tracker.begin("codex:a")
        tracker.finish("codex:a", succeeded: true)
        XCTAssertEqual(tracker.phase(for: "codex:a"), .restarted)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(tracker.phase(for: "codex:a"))
    }

    func testNewRestartDuringConfirmationIsNotClearedByOldTimer() async throws {
        let tracker = SessionRestartTracker(confirmationDuration: .milliseconds(50))
        tracker.begin("codex:a")
        tracker.finish("codex:a", succeeded: true)
        XCTAssertTrue(tracker.begin("codex:a"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(tracker.phase(for: "codex:a"), .restarting)
    }
}
