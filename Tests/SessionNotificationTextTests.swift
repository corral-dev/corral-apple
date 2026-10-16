import XCTest
@testable import Corral

final class SessionNotificationTextTests: XCTestCase {
    func testKnownKindsResolve() {
        XCTAssertNotNil(SessionNotificationText.title(forKind: "waiting"))
        XCTAssertNotNil(SessionNotificationText.title(forKind: "completed"))
        XCTAssertNotNil(SessionNotificationText.title(forKind: "aborted"))
    }

    func testUnknownKindReturnsNil() {
        XCTAssertNil(SessionNotificationText.title(forKind: "nope"))
        XCTAssertNil(SessionNotificationText.title(forKind: ""))
    }

    func testKnownTitlesAreDistinct() {
        let waiting = SessionNotificationText.title(forKind: "waiting")
        let completed = SessionNotificationText.title(forKind: "completed")
        let aborted = SessionNotificationText.title(forKind: "aborted")
        XCTAssertNotEqual(waiting, completed)
        XCTAssertNotEqual(waiting, aborted)
        XCTAssertNotEqual(completed, aborted)
    }
}
