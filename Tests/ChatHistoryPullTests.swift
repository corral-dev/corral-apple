import XCTest
@testable import Corral

final class ChatHistoryPullTests: XCTestCase {
    func testReleaseAndReboundOnlyLoadOnce() {
        var pull = ChatHistoryPullState()
        pull.begin()
        pull.update(distance: 80)
        XCTAssertTrue(pull.release())
        pull.update(distance: 100)
        XCTAssertFalse(pull.release())
        XCTAssertNil(pull.progress)
    }

    func testRetreatCancelsAndNextGestureCanLoad() {
        var pull = ChatHistoryPullState()
        pull.begin()
        pull.update(distance: 100)
        pull.update(distance: 40)
        XCTAssertEqual(pull.progress, 0.5)
        XCTAssertFalse(pull.release())
        pull.begin()
        pull.update(distance: 90)
        XCTAssertTrue(pull.release())
    }

    func testIdleInvalidGeometryAndLeavingDoNotLoad() {
        var pull = ChatHistoryPullState()
        pull.update(distance: 100)
        XCTAssertFalse(pull.release())
        pull.begin()
        pull.update(distance: .nan)
        XCTAssertFalse(pull.release())
        pull.begin()
        pull.update(distance: 100)
        pull.reset()
        XCTAssertFalse(pull.release())
    }
}
