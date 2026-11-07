import AppKit
import SwiftUI

private final class PaneClickTarget: NSView {
    var presses = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { presses += 1 }
    override func rightMouseDown(with event: NSEvent) { presses += 1 }
}

/// Mount the production composer and event observer in independent native slots.
/// Events stay in this process: no cursor movement, global input or host sends.
@MainActor enum PaneInteractionProbe {
    static func run() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 520))
        window.contentView = content
        window.orderBack(nil)
        defer { window.close() }
        var active = -1
        var states: [ComposerState] = []
        var hosts: [NSHostingView<AnyView>] = []
        var observers: [MacPaneInteraction.EventView] = []
        var messages: [NSTextView] = []
        var targets: [PaneClickTarget] = []
        for index in 0..<4 {
            let state = ComposerState()
            let host = NSHostingView(rootView: AnyView(ComposerScreen(state: state)))
            host.frame = NSRect(x: CGFloat(index) * 300, y: 0, width: 300, height: 520)
            content.addSubview(host)
            let message = NSTextView(frame: NSRect(x: 15, y: 250, width: 270, height: 70))
            message.string = "Selected reply in pane \(index + 1)"
            message.isEditable = false
            message.isSelectable = true
            host.addSubview(message)
            let target = PaneClickTarget(frame: NSRect(x: 5, y: 460, width: 290, height: 45))
            host.addSubview(target)
            let observer = MacPaneInteraction.EventView(frame: host.bounds)
            observer.autoresizingMask = [.width, .height]
            observer.isPresented = true
            observer.isActive = index == active
            observer.isChat = true
            observer.inputRoot = { [weak host] in host }
            observer.activate = {
                active = index
                for (slot, other) in observers.enumerated() { other.isActive = slot == index }
            }
            host.addSubview(observer)
            states.append(state); hosts.append(host); messages.append(message)
            targets.append(target); observers.append(observer)
        }
        func pump() { ComposerProbe.pump(content) }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { fatalError("No mouse event") }
            NSApp.sendEvent(event)
            pump()
        }
        func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { fatalError("No key event") }
            NSApp.sendEvent(event)
            pump()
        }
        pump()
        for index in 0..<4 {
            let point = targets[index].convert(NSPoint(x: 50, y: 20), to: nil)
            let before = targets[index].presses
            mouse(.leftMouseDown, at: point)
            precondition(active == index, "Slot \(index + 1) did not activate")
            precondition(targets[index].presses == before + 1, "Activation consumed native click")
        }
        key(6, "z")
        precondition(states[3].text == "z" && states[0].text.isEmpty,
                     "Clicking a pane kept the previous pane's composer")
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        print("PASS all four native slots activate without consuming clicked actions; composer follows clicks")

        // Position-only changes need no layout/cache publication. Stale frame
        // dictionaries cannot affect current native hit geometry.
        hosts[2].frame.origin.x = 0
        hosts[0].frame.origin.x = 600
        mouse(.leftMouseDown, at: targets[2].convert(NSPoint(x: 50, y: 20), to: nil))
        precondition(active == 2, "Third pane did not activate after moving to another slot")
        let copyBoard = NSPasteboard.withUniqueName()
        let selected = NSRange(location: 0, length: 8)
        window.makeFirstResponder(messages[2]); pump(); messages[2].setSelectedRange(selected)
        precondition(messages[2].writeSelection(to: copyBoard, types: messages[2].writablePasteboardTypes),
                     "Native selection copy failed")
        precondition(copyBoard.string(forType: .string) == "Selected", "Selection copy changed")
        key(8, "c", flags: .command)
        precondition(window.firstResponder === messages[2], "Copy shortcut stole selection focus")
        key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), flags: [.function, .numericPad])
        precondition(window.firstResponder === messages[2], "Selection navigation stole focus")
        key(0, "a")
        precondition(states[2].text == "a", "First typed character after selection was lost")
        precondition(states.enumerated().allSatisfy { $0.offset == 2 || $0.element.text.isEmpty }, "Typing leaked into another pane")
        guard let editor = window.firstResponder as? NSTextView, editor.isEditable else { fatalError("Composer not editing") }
        editor.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        pump()
        precondition(editor.hasMarkedText(), "Native composer IME unavailable")
        key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), flags: [.function, .numericPad])
        precondition(window.firstResponder === editor, "Input routing stole an active IME")
        editor.unmarkText()
        print("PASS selected conversation Copy/navigation, first-key draft routing, isolation and native IME")

        // An unrelated editable field keeps keyboard ownership, as do terminals.
        let search = NSTextField(frame: NSRect(x: 20, y: 200, width: 200, height: 30))
        content.addSubview(search); window.makeFirstResponder(search); pump()
        key(11, "b")
        precondition(search.stringValue == "b", "Pane routing stole another editable control")
        window.makeFirstResponder(messages[2]); observers[2].isChat = false
        key(2, "d")
        precondition(window.firstResponder === messages[2], "Chat routing stole terminal input")
        observers[2].isChat = true
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        guard let foreign = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 30, y: 30),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: other.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { fatalError("No foreign click") }
        for observer in observers { _ = observer.handle(foreign) }
        precondition(active == 2, "Another window activated a pane")
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        active = -1
        mouse(.leftMouseDown, at: targets[2].convert(NSPoint(x: 50, y: 20), to: nil))
        precondition(active == -1, "Attached sheet allowed pane activation")
        window.endSheet(sheet); sheet.orderOut(nil); pump(); sheet.close()
        observers[2].isPresented = false
        mouse(.leftMouseDown, at: targets[2].convert(NSPoint(x: 50, y: 20), to: nil))
        precondition(active == -1, "Dormant pane changed focus")
        observers[2].isPresented = true
        observers[2].removeFromSuperview()
        mouse(.leftMouseDown, at: targets[2].convert(NSPoint(x: 50, y: 20), to: nil))
        precondition(active == -1, "Detached observer retained its monitor")
        hosts[2].addSubview(observers[2])
        mouse(.leftMouseDown, at: targets[2].convert(NSPoint(x: 50, y: 20), to: nil))
        precondition(active == 2, "Reattached observer did not resume monitoring")
        mouse(.rightMouseDown, at: targets[1].convert(NSPoint(x: 50, y: 20), to: nil))
        precondition(active == 1, "Right click did not activate its pane")
        for observer in observers { observer.stopMonitoring() }
        copyBoard.releaseGlobally()
        precondition(states.allSatisfy { $0.sends == 0 }, "Input probe submitted a prompt")
        print("PASS other editors, terminal mode, foreign windows, sheets, dormant panes, right clicks and monitor lifecycle; no sends")
    }
}
