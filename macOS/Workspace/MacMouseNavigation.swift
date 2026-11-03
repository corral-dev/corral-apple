import AppKit
import SwiftUI

/// Observes auxiliary clicks across this workspace's window, including native
/// terminal/text views, without becoming a hit target or changing key ownership.
struct MacMouseNavigation: NSViewRepresentable {
    var navigate: (Int) -> Void

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.navigate = navigate
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.navigate = navigate
    }

    static func dismantleNSView(_ view: EventView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class EventView: NSView {
        var navigate: ((Int) -> Void)?
        private var monitor: Any?
        private var pressedButtons: Set<Int> = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressedButtons.removeAll()
        }

        /// Returning nil consumes only the two navigation buttons. Matching the
        /// press prevents duplicate/orphan releases from becoming extra visits.
        func handle(_ event: NSEvent) -> NSEvent? {
            guard [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type),
                  event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
            guard let window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else {
                pressedButtons.remove(event.buttonNumber)
                return event
            }
            switch event.type {
            case .otherMouseDown:
                pressedButtons.insert(event.buttonNumber)
            case .otherMouseUp:
                if pressedButtons.remove(event.buttonNumber) != nil {
                    navigate?(event.buttonNumber == 3 ? -1 : 1)
                }
            default:
                break
            }
            return nil
        }
    }
}
