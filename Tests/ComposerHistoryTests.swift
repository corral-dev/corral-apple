@testable import Corral
import XCTest

/// Up / Down recall of the session's own prompts in the composer.
final class ComposerHistoryTests: XCTestCase {
    private let entries = ["first", "second", "third"]

    func testUpStepsNewestToOldestAndStopsAtOldest() {
        var history = ComposerHistory()
        XCTAssertEqual(history.older(entries: entries, current: ""), "third")
        XCTAssertEqual(history.older(entries: entries, current: "third"), "second")
        XCTAssertEqual(history.older(entries: entries, current: "second"), "first")
        XCTAssertNil(history.older(entries: entries, current: "first"))
        XCTAssertTrue(history.isShowingUnchanged("first"))
    }

    func testDownPastNewestRestoresDraft() {
        var history = ComposerHistory()
        XCTAssertNil(history.newer(entries: entries))
        XCTAssertEqual(history.older(entries: entries, current: "half typed"), "third")
        XCTAssertEqual(history.older(entries: entries, current: "third"), "second")
        XCTAssertEqual(history.newer(entries: entries), "third")
        XCTAssertEqual(history.newer(entries: entries), "half typed")
        XCTAssertFalse(history.isBrowsing)
        XCTAssertNil(history.newer(entries: entries))
    }

    func testEditedEntryIsNotUnchanged() {
        var history = ComposerHistory()
        _ = history.older(entries: entries, current: "")
        XCTAssertFalse(history.isShowingUnchanged("third!"))
    }

    func testEmptyHistoryIsNotHandled() {
        var history = ComposerHistory()
        XCTAssertNil(history.older(entries: [], current: "draft"))
        XCTAssertFalse(history.isBrowsing)
    }

    func testNewPromptArrivingKeepsPosition() {
        var history = ComposerHistory()
        _ = history.older(entries: entries, current: "")
        XCTAssertEqual(history.older(entries: entries + ["fourth"], current: "third"), "second")
        XCTAssertEqual(history.newer(entries: entries + ["fourth"]), "third")
        XCTAssertEqual(history.newer(entries: entries + ["fourth"]), "fourth")
    }

    func testShrunkHistoryClampsIndex() {
        var history = ComposerHistory()
        _ = history.older(entries: entries, current: "")
        XCTAssertEqual(history.older(entries: ["only"], current: "third"), "only")
    }

    func testResetStartsFromNewestAgain() {
        var history = ComposerHistory()
        _ = history.older(entries: entries, current: "")
        _ = history.older(entries: entries, current: "third")
        history.reset()
        XCTAssertEqual(history.older(entries: entries, current: ""), "third")
    }
}
