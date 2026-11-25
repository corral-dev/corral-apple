import SwiftTerm
import UIKit
import XCTest
@testable import Corral

@MainActor
final class TerminalFunctionKeypadTests: XCTestCase {
    func testActualShortcutToggleKeepsStripAndRestoresSystemInput() throws {
        let terminal = ShellTerminalHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let strip = try XCTUnwrap(terminal.inputAccessoryView as? TerminalShortcutStrip)
        let toggle = try shortcut("keyboard", in: strip)

        XCTAssertNil(terminal.inputView)
        XCTAssertFalse(toggle.isSelected)
        toggle.sendActions(for: .primaryActionTriggered)
        let keypad = try XCTUnwrap(terminal.inputView as? TerminalFunctionKeypad)
        XCTAssertTrue(terminal.inputAccessoryView === strip)
        XCTAssertTrue(toggle.isSelected)
        XCTAssertEqual(toggle.accessibilityLabel, String(localized: "terminal.keypad.show_system", bundle: .main))
        terminal.reloadInputViews()
        XCTAssertTrue(terminal.inputView === keypad, "A UIKit reload must not rebuild the keypad")
        toggle.sendActions(for: .primaryActionTriggered)
        XCTAssertNil(terminal.inputView)
        XCTAssertTrue(terminal.inputAccessoryView === strip)
        XCTAssertFalse(toggle.isSelected)
    }

    func testShortcutRowDropsBothSeparatorsAndFillsTheWidth() throws {
        let terminal = ShellTerminalHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let strip = try XCTUnwrap(terminal.inputAccessoryView as? TerminalShortcutStrip)
        let expected = ["escape", "control", "tab", "tilde", "slash", "left", "down", "up", "right", "touch", "keyboard"]
            .map { "terminal.shortcut.\($0)" }
        for width: CGFloat in [320, 390, 430] {
            strip.frame.size.width = width
            strip.setNeedsLayout()
            strip.layoutIfNeeded()
            let visible = buttons(in: strip).filter { !$0.isHidden }
            XCTAssertEqual(visible.compactMap(\.accessibilityIdentifier), expected)
            XCTAssertFalse(visible.contains { ["|", "-"].contains($0.configuration?.title ?? "") })
            let slots = visible.map { $0.convert($0.bounds, to: strip) }
            XCTAssertTrue(slots.allSatisfy { !$0.isEmpty && strip.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) })
            for (left, right) in zip(slots, slots.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5)
            }
            XCTAssertEqual(try XCTUnwrap(slots.first).minX, TerminalShortcutStrip.horizontalInset, accuracy: 0.5)
            let lastMaxX = try XCTUnwrap(slots.last).maxX
            XCTAssertEqual(width - lastMaxX, TerminalShortcutStrip.horizontalInset, accuracy: 0.5)
            let widths = slots.map(\.width)
            XCTAssertEqual(widths.max() ?? 0, widths.min() ?? 1, accuracy: 0.5, "Keys share the row width")
            XCTAssertLessThanOrEqual(widths.max() ?? 0, TerminalShortcutStrip.maxKeyWidth + 0.5)
        }
        strip.frame.size.width = 1024
        strip.setNeedsLayout()
        strip.layoutIfNeeded()
        let wide = buttons(in: strip).filter { !$0.isHidden }.map { $0.convert($0.bounds, to: strip) }
        let widest = try XCTUnwrap(wide.map(\.width).max())
        XCTAssertLessThanOrEqual(widest, TerminalShortcutStrip.maxKeyWidth + 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(wide.first).minX, 100, "A wide keyboard centers the capped row")
    }

    func testShortcutKeysKeepLiteralSymbolControlAndMouseBehavior() throws {
        let terminal = ShellTerminalHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let strip = try XCTUnwrap(terminal.inputAccessoryView as? TerminalShortcutStrip)
        let input = KeypadInputRecorder()
        terminal.terminalDelegate = input
        func press(_ key: String) throws {
            try shortcut(key, in: strip).sendActions(for: .primaryActionTriggered)
        }

        try press("control")
        XCTAssertTrue(terminal.controlModifier)
        XCTAssertTrue(try shortcut("control", in: strip).isSelected)
        try press("tilde")
        XCTAssertTrue(terminal.controlModifier, "A literal shortcut leaves the modifier armed")
        terminal.insertText("c")
        XCTAssertFalse(terminal.controlModifier)
        XCTAssertFalse(try shortcut("control", in: strip).isSelected)
        try press("escape")
        try press("tab")
        try press("up")
        XCTAssertEqual(input.bytes, [[0x7e], [0x03], [0x1b], [0x09], [0x1b, 0x5b, 0x41]])

        try press("touch")
        XCTAssertFalse(terminal.allowMouseReporting)
        XCTAssertTrue(try shortcut("touch", in: strip).isSelected)
        try press("touch")
        XCTAssertTrue(terminal.allowMouseReporting)
        XCTAssertFalse(try shortcut("touch", in: strip).isSelected)
    }

    func testEveryKeyUsesTheSameKeycap() throws {
        let terminal = ShellTerminalHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let strip = try XCTUnwrap(terminal.inputAccessoryView as? TerminalShortcutStrip)
        try shortcut("keyboard", in: strip).sendActions(for: .primaryActionTriggered)
        let keypad = try XCTUnwrap(terminal.inputView as? TerminalFunctionKeypad)
        let shortcuts = buttons(in: strip)
        let keys = buttons(in: keypad)
        XCTAssertEqual(shortcuts.count, 11)
        XCTAssertEqual(keys.count, 30)
        for button in shortcuts + keys {
            let configuration = try XCTUnwrap(button.configuration)
            XCTAssertEqual(configuration.cornerStyle, .medium)
            XCTAssertEqual(configuration.background.backgroundInsets, TerminalKeyButton.backgroundInsets)
            for appearance: UIUserInterfaceStyle in [.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: appearance)
                XCTAssertEqual(configuration.baseBackgroundColor?.resolvedColor(with: traits),
                               TerminalKeyButton.fill.resolvedColor(with: traits),
                               "\(button.accessibilityIdentifier ?? "") must carry a visible cap")
            }
        }
    }

    func testAllKeySlotsStayInBoundsAfterWidthChanges() throws {
        let terminal = ShellTerminalHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let frame = CGRect(x: 0, y: 0, width: 390, height: 156)
        let keypad = TerminalFunctionKeypad(frame: frame, terminal: terminal)
        for width: CGFloat in [320, 390, 768] {
            keypad.frame.size.width = width
            keypad.layoutIfNeeded()
            let keys = buttons(in: keypad)
            XCTAssertEqual(keys.count, 30)
            XCTAssertEqual(Set(keys.compactMap(\.accessibilityIdentifier)).count, 30)
            let slots = keys.map { $0.convert($0.bounds, to: keypad) }
            for (key, slot) in zip(keys, slots) {
                XCTAssertTrue(keypad.bounds.contains(slot))
                XCTAssertLessThanOrEqual(slot.width, TerminalFunctionKeypad.maxKeyWidth + 0.5)
                XCTAssertGreaterThan(slot.height, 44)
                XCTAssertTrue(key.accessibilityTraits.contains(.keyboardKey))
                XCTAssertFalse(key.accessibilityLabel?.isEmpty ?? true)
                XCTAssertEqual(key.configuration?.titleLineBreakMode, .byClipping, "Terminal key titles must remain on one line")
            }
            let columns = Dictionary(grouping: slots, by: { Int($0.minX) }).values.compactMap { $0.first?.width }
            XCTAssertEqual(columns.max() ?? 0, columns.min() ?? 1, accuracy: 0.5, "Keypad columns share the width")
            let firstColumnMinX = try XCTUnwrap(slots.map(\.minX).min())
            let lastColumnMaxX = try XCTUnwrap(slots.map(\.maxX).max())
            if width > 10 * TerminalFunctionKeypad.maxKeyWidth {
                XCTAssertGreaterThan(firstColumnMinX, TerminalFunctionKeypad.horizontalInset, "A wide keyboard centers the capped grid")
            } else {
                XCTAssertEqual(firstColumnMinX, TerminalFunctionKeypad.horizontalInset, accuracy: 0.5)
                XCTAssertEqual(width - lastColumnMaxX, TerminalFunctionKeypad.horizontalInset, accuracy: 0.5)
            }
        }
    }

    func testKeyActionsSendSwiftTermSequences() throws {
        let terminal = ShellTerminalHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let input = KeypadInputRecorder()
        terminal.terminalDelegate = input
        let frame = CGRect(x: 0, y: 0, width: 390, height: 156)
        let keypad = TerminalFunctionKeypad(frame: frame, terminal: terminal)
        let keys = buttons(in: keypad)

        func press(_ identifier: String) throws {
            let key = try XCTUnwrap(keys.first { $0.accessibilityIdentifier == "terminal.keypad.\(identifier)" })
            key.sendActions(for: .primaryActionTriggered)
        }
        for index in 1...10 { try press("F\(index)") }
        for symbol in "[]{}<>&+-*=%`\\" { try press(String(symbol)) }
        for key in ["Ins", "Home", "PgUp", "forward-delete", "End", "PgDn"] { try press(key) }
        let expected = Array(EscapeSequences.cmdF.prefix(10)) + "[]{}<>&+-*=%`\\".map { Array(String($0).utf8) } + [
            EscapeSequences.cmdInsert, EscapeSequences.moveHomeNormal, EscapeSequences.cmdPageUp,
            EscapeSequences.cmdDelKey, EscapeSequences.moveEndNormal, EscapeSequences.cmdPageDown
        ]
        XCTAssertEqual(input.bytes, expected)

        terminal.feed(text: "\u{1B}[?1h")
        try press("Home")
        try press("End")
        XCTAssertEqual(Array(input.bytes.suffix(2)), [EscapeSequences.moveHomeApp, EscapeSequences.moveEndApp])
    }

    func testHostedKeyboardRespectsSafeAreaInsetInsteadOfSystemLayoutMargins() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let terminal = ShellTerminalHost(frame: .zero)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        terminal.frame = controller.view.bounds
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(terminal)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        let strip = try XCTUnwrap(terminal.inputAccessoryView as? TerminalShortcutStrip)
        XCTAssertTrue(terminal.becomeFirstResponder())
        try await waitUntil { strip.window != nil && strip.bounds.width > 0 }
        try await settleLayout()

        let stripSlots = buttons(in: strip)
            .filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: strip) }
        let stripFirstMinX = try XCTUnwrap(stripSlots.map(\.minX).min())
        let stripLastMaxX = try XCTUnwrap(stripSlots.map(\.maxX).max())
        let stripMaxSpan = CGFloat(stripSlots.count) * TerminalShortcutStrip.maxKeyWidth
            + CGFloat(stripSlots.count - 1) * TerminalShortcutStrip.keySpacing
        XCTAssertGreaterThanOrEqual(stripFirstMinX, TerminalShortcutStrip.horizontalInset - 0.5)
        XCTAssertLessThanOrEqual(stripLastMaxX, strip.bounds.width - TerminalShortcutStrip.horizontalInset + 0.5)
        if strip.bounds.width - 2 * TerminalShortcutStrip.horizontalInset <= stripMaxSpan {
            XCTAssertEqual(stripFirstMinX, TerminalShortcutStrip.horizontalInset, accuracy: 0.5)
            XCTAssertEqual(strip.bounds.width - stripLastMaxX, TerminalShortcutStrip.horizontalInset, accuracy: 0.5)
        }

        try shortcut("keyboard", in: strip).sendActions(for: .primaryActionTriggered)
        let keypad = try XCTUnwrap(terminal.inputView as? TerminalFunctionKeypad)
        try await waitUntil { keypad.window != nil && keypad.bounds.width > 0 }
        try await settleLayout()

        let keypadSlots = buttons(in: keypad)
            .map { $0.convert($0.bounds, to: keypad) }
        let keypadFirstMinX = try XCTUnwrap(keypadSlots.map(\.minX).min())
        let keypadLastMaxX = try XCTUnwrap(keypadSlots.map(\.maxX).max())
        let keypadSafeRect = keypad.safeAreaLayoutGuide.layoutFrame
        let keypadMaxSpan = 10 * TerminalFunctionKeypad.maxKeyWidth + 9 * TerminalShortcutStrip.keySpacing
        XCTAssertGreaterThanOrEqual(keypadFirstMinX, TerminalFunctionKeypad.horizontalInset - 0.5)
        XCTAssertLessThanOrEqual(keypadLastMaxX, keypad.bounds.width - TerminalFunctionKeypad.horizontalInset + 0.5)
        if keypad.bounds.width - 2 * TerminalFunctionKeypad.horizontalInset <= keypadMaxSpan {
            XCTAssertEqual(keypadFirstMinX, TerminalFunctionKeypad.horizontalInset, accuracy: 0.5)
            XCTAssertEqual(keypad.bounds.width - keypadLastMaxX, TerminalFunctionKeypad.horizontalInset, accuracy: 0.5)
            XCTAssertEqual(keypadFirstMinX, stripFirstMinX, accuracy: 0.5)
            XCTAssertEqual(keypadLastMaxX, stripLastMaxX, accuracy: 0.5)
        }
        let verticalBounds = CGRect(
            x: 0,
            y: TerminalFunctionKeypad.topInset,
            width: keypad.bounds.width,
            height: max(0, keypadSafeRect.maxY - TerminalFunctionKeypad.bottomInset - TerminalFunctionKeypad.topInset)
        )
        for slot in keypadSlots {
            XCTAssertTrue(verticalBounds.insetBy(dx: -0.5, dy: -0.5).contains(slot))
        }
    }

    private func waitUntil(timeout: Duration = .seconds(5), condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for hosted keyboard layout")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func settleLayout() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    private func shortcut(_ name: String, in strip: TerminalShortcutStrip) throws -> UIButton {
        try XCTUnwrap(buttons(in: strip).first { $0.accessibilityIdentifier == "terminal.shortcut.\(name)" })
    }

    private func buttons(in view: UIView) -> [UIButton] {
        if let button = view as? UIButton { return [button] }
        return view.subviews.flatMap { buttons(in: $0) }
    }
}

private final class KeypadInputRecorder: TerminalViewDelegate {
    var bytes: [[UInt8]] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
