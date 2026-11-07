import AppKit
import SwiftUI

/// Observes each shown slot at its current native geometry, without becoming
/// a hit target. Cached frames can lag behind equal-slot layout or key migration.
struct MacPaneInteraction: NSViewRepresentable {
    var isPresented: Bool
    var isActive: Bool
    var isChat: Bool
    var inputRoot: () -> NSView?
    var activate: () -> Void

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.isPresented = isPresented
        view.isActive = isActive
        view.isChat = isChat
        view.inputRoot = inputRoot
        view.activate = activate
    }

    static func dismantleNSView(_ view: EventView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class EventView: NSView {
        var isPresented = false
        var isActive = false
        var isChat = false
        var inputRoot: (() -> NSView?)?
        var activate: (() -> Void)?
        private var monitor: Any?
        private var clickSerial = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            clickSerial &+= 1
        }

        func handle(_ event: NSEvent) -> NSEvent {
            guard isPresented, !isHiddenOrHasHiddenAncestor,
                  let window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            if event.type == .keyDown {
                if isActive, isChat, Self.beginsComposerInput(event),
                   !Self.isEditing(window.firstResponder) {
                    focusComposer(in: window)
                }
                return event
            }
            guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
                  // Side buttons belong to window history, not pane activation.
                  event.type != .otherMouseDown || event.buttonNumber == 2,
                  bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else { return event }
            activate?()
            clickSerial &+= 1
            let serial = clickSerial
            // Let selection, links and buttons handle the original click first.
            // A right-click must keep the native context menu's responder.
            if event.type == .leftMouseDown {
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.window === window,
                          self.clickSerial == serial, self.isPresented, self.isActive, self.isChat,
                          window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                    if let text = window.firstResponder as? NSTextView,
                       self.owns(text), text.isEditable || text.isSelectable { return }
                    self.focusComposer(in: window)
                }
            }
            return event
        }

        /// Do not take selection navigation, shortcuts or another editor's IME.
        /// Option/Shift and dead-key input use AppKit's ordinary input context.
        static func beginsComposerInput(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            let flags = event.modifierFlags
            if flags.contains(.command) {
                return !flags.contains(.control)
                    && event.charactersIgnoringModifiers?.lowercased() == "v"
            }
            guard !flags.contains(.control),
                  ![48, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(event.keyCode)
            else { return false }
            // Return/Backspace target the draft; function/navigation keys do not.
            if event.keyCode == 36 || event.keyCode == 51 || event.keyCode == 76 { return true }
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
            return !characters.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }
        }

        private static func isEditing(_ responder: NSResponder?) -> Bool {
            if let text = responder as? NSTextView { return text.isEditable }
            if let field = responder as? NSTextField { return field.isEditable }
            return false
        }

        private func owns(_ view: NSView) -> Bool {
            guard let root = inputRoot?() else { return false }
            if view === root || view.isDescendant(of: root) { return true }
            // AppKit's shared field editor is a window child; its native field
            // delegate, not the editor's superview, identifies pane ownership.
            if let text = view as? NSTextView, text.isFieldEditor,
               let field = text.delegate as? NSView {
                return field === root || field.isDescendant(of: root)
            }
            return false
        }

        private func focusComposer(in window: NSWindow) {
            guard let root = inputRoot?(), root.window === window,
                  !root.isHiddenOrHasHiddenAncestor,
                  let field = MacComposerInputAnchor.field(in: root), field.acceptsFirstResponder else { return }
            // Return the untouched event to AppKit after switching responder:
            // SwiftUI's native field handles IME, paste, caret and submission.
            window.makeFirstResponder(field)
        }

    }
}
