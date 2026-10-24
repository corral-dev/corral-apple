@testable import Corral
import XCTest

final class SessionNavigationHistoryTests: XCTestCase {
    func testReturnBranchAndRepeatedFocus() {
        var history = SessionNavigationHistory()
        history.visit("old")
        history.visit("today")
        history.visit("today")
        XCTAssertEqual(history.keys, ["old", "today"])
        XCTAssertEqual(history.move(to: 0), "old")
        XCTAssertTrue(history.canGoForward)
        history.visit("third")
        XCTAssertEqual(history.keys, ["old", "third"])
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.move(to: 99))
        XCTAssertEqual(history.current, "third")
    }

    func testDeletedAndCanonicalTargetsAndBound() {
        var history = SessionNavigationHistory()
        history.visit("provisional")
        history.visit("deleted")
        history.visit("last")
        history.replace("provisional", with: "canonical")
        history.remove("deleted")
        XCTAssertEqual(history.move(to: 0), "canonical")
        XCTAssertEqual(history.move(to: 1), "last")
        for index in 0..<150 { history.visit("session-\(index)") }
        XCTAssertEqual(history.keys.count, SessionNavigationHistory.limit)
        XCTAssertEqual(history.current, "session-149")
        history.remove("session-149")
        XCTAssertEqual(history.current, "session-148")
    }
}
