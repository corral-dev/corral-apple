import AppKit

@main
struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        let observer = MacMouseNavigation.EventView()
        window.contentView?.addSubview(observer)
        defer { observer.stopMonitoring() }
        var steps: [Int] = []
        var history = SessionNavigationHistory()
        ["a", "b", "c"].forEach { history.visit($0) }
        observer.navigate = { step in
            steps.append(step)
            history.move(to: history.index + step)
        }

        func event(_ type: NSEvent.EventType, button: Int, in target: NSWindow? = nil) throws -> NSEvent {
            guard let native = NSEvent.mouseEvent(with: type, location: NSPoint(x: 30, y: 30),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: (target ?? window).windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0), let cg = native.cgEvent else {
                throw Failure.event
            }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            guard let result = NSEvent(cgEvent: cg), result.buttonNumber == button,
                  result.window === (target ?? window) else { throw Failure.event }
            return result
        }
        func consume(_ type: NSEvent.EventType, button: Int) throws {
            let result = observer.handle(try event(type, button: button))
            precondition(result == nil, "side-button events are consumed")
        }
        func click(_ button: Int) throws {
            // In-process AppKit dispatch only: no CGEvent posting or pointer movement.
            NSApp.sendEvent(try event(.otherMouseDown, button: button))
            NSApp.sendEvent(try event(.otherMouseUp, button: button))
        }

        try click(3)
        precondition(steps == [-1] && history.current == "b", "local monitor must navigate back once")
        try click(4)
        precondition(steps == [-1, 1] && history.current == "c", "forward uses the same history")
        try click(4)
        precondition(history.current == "c", "forward boundary is a no-op")
        try click(3); try click(3); try click(3)
        precondition(history.current == "a", "back boundary is a no-op")
        let count = steps.count
        try consume(.otherMouseUp, button: 3)
        precondition(steps.count == count, "duplicate/orphan releases must not navigate")

        for button in [0, 1, 2, 5, 8] {
            let native = try event(.otherMouseDown, button: button)
            precondition(observer.handle(native) === native, "unrelated buttons must pass through")
        }
        let left = try event(.leftMouseDown, button: 0)
        precondition(observer.handle(left) === left)
        let unrelated = try event(.otherMouseDown, button: 3, in: otherWindow)
        precondition(observer.handle(unrelated) === unrelated, "other windows are isolated")
        NSApp.sendEvent(unrelated)
        NSApp.sendEvent(try event(.otherMouseUp, button: 3, in: otherWindow))
        precondition(steps.count == count)

        let responder = window.firstResponder
        try consume(.otherMouseDown, button: 3)
        try consume(.otherMouseDragged, button: 3)
        precondition(steps.count == count, "press and drag do not navigate")
        try consume(.otherMouseUp, button: 3)
        precondition(steps.count == count + 1 && window.firstResponder === responder)
        precondition(observer.hitTest(.zero) == nil, "observer is never a click target")

        // A sheet blocks even parent-window events and clears a pending press.
        _ = observer.handle(try event(.otherMouseDown, button: 4))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        let blocked = try event(.otherMouseUp, button: 4)
        precondition(observer.handle(blocked) === blocked)
        precondition(steps.count == count + 1)
        window.endSheet(sheet)
        try consume(.otherMouseUp, button: 4)
        precondition(steps.count == count + 1)

        let modal = NSApp.beginModalSession(for: otherWindow)
        let modalEvent = try event(.otherMouseDown, button: 3)
        precondition(observer.handle(modalEvent) === modalEvent)
        NSApp.endModalSession(modal)

        let beforeDetach = steps.count
        observer.removeFromSuperview()
        try click(3)
        precondition(steps.count == beforeDetach, "detaching removes the local monitor")
        window.contentView?.addSubview(observer)
        window.contentView?.addSubview(observer)
        try click(4)
        precondition(steps.count == beforeDetach + 1, "reattaching installs exactly one monitor")
        MacMouseNavigation.dismantleNSView(observer, coordinator: ())
        try click(3)
        precondition(steps.count == beforeDetach + 1, "representable dismantling removes the monitor")
        print("PASS: mouse routing, history boundaries, unrelated buttons, window/modal isolation, focus and monitor lifecycle")
    }

    enum Failure: Error { case event }
}
