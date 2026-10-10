@testable import Corral
import XCTest

/// A Your prompts jump glides to a nearby prompt and fades through to a far one.
@MainActor
final class ChatJumpPlanTests: XCTestCase {
    private let ids = (1...100).map { "message-\($0)" }

    func testNearbyTargetGlides() {
        XCTAssertTrue(ChatJumpPlan.glides(in: ids, target: "message-70", visible: "message-95"))
    }

    func testFarTargetFades() {
        XCTAssertFalse(ChatJumpPlan.glides(in: ids, target: "message-5", visible: "message-95"))
        XCTAssertFalse(ChatJumpPlan.glides(in: ids, target: "message-95", visible: "message-5"))
    }

    func testUnknownViewportAssumesLatest() {
        XCTAssertTrue(ChatJumpPlan.glides(in: ids, target: "message-80", visible: nil))
        XCTAssertFalse(ChatJumpPlan.glides(in: ids, target: "message-1", visible: nil))
    }

    func testTargetNotLoadedFades() {
        XCTAssertFalse(ChatJumpPlan.glides(in: ids, target: "message-999", visible: "message-100"))
    }
}
