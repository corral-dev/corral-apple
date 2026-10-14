import AppKit
import SwiftTerm

/// SwiftTerm's view with the host stream's rules: replies the emulator
/// generates while drawing host output are dropped (tmux already answered the
/// agent's queries), mouse reports leave only the focused pane of the key
/// window, and paste goes to the host paste path.
final class StreamTerminalView: SwiftTerm.TerminalView {
    var onPaste: ((String) -> Void)?
    private var feedingHost = false

    func feedFromHost(_ data: Data) {
        feedingHost = true
        defer { feedingHost = false }
        feedPreservingSelection(data)
    }

    /// A reset or alternate-screen switch replaces the selected document.
    override func bufferActivated(source: Terminal) {
        selection?.selectNone()
        super.bufferActivated(source: source)
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Outside a feed these are mouse reports. Agents such as Claude Code
        // track every pointer move, so only the focused terminal of the key
        // window reports; hovering over a background pane must not type.
        // The wheel is a deliberate gesture: AppKit delivers it to the pane
        // under the pointer, which scrolls whether selected or not, as
        // everywhere else on macOS. (SwiftTerm's scrollWheel cannot be overridden.)
        guard !feedingHost else { return }
        let wheel = NSApp.currentEvent?.type == .scrollWheel
        guard wheel || (window?.isKeyWindow == true && window?.firstResponder === self) else { return }
        super.send(source: source, data: data)
    }

    /// A click into the terminal takes the keyboard, whichever of SwiftTerm's
    /// subviews received it.
    override func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        onPaste?(text)
    }
}

