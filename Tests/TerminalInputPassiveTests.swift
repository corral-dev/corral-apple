@testable import Corral
import XCTest

/// Focus reports are the emulator's, not the person's: they must not retire a prompt jump.
final class TerminalInputPassiveTests: XCTestCase {
    func testFocusReportsAreRecognised() {
        XCTAssertTrue(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[I".utf8))))
        XCTAssertTrue(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[O\u{1b}[I".utf8))))
    }

    func testTypingIsNotAFocusReport() {
        XCTAssertFalse(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[A".utf8))))
        XCTAssertFalse(TerminalInputSender.isFocusReport(ArraySlice(Array("abc".utf8))))
        XCTAssertFalse(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[Ix".utf8))))
        XCTAssertFalse(TerminalInputSender.isFocusReport([]))
    }
}
