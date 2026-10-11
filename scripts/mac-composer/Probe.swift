import AppKit
import SwiftUI
import Observation

@Observable @MainActor final class ComposerState {
    var text = ""
    var attachments: [DraftImageAttachment] = []
    var revision = 0
    var sends = 0
}

private struct ComposerScreen: View {
    let state: ComposerState
    var body: some View {
        @Bindable var state = state
        VStack {
            Text("Incoming message revision \(state.revision)")
            Spacer()
            ComposerBar(text: $state.text, attachments: $state.attachments,
                        history: ["Older prompt", "Newest 中文🙂 prompt"]) { _, _ in state.sends += 1 }
        }
        .padding()
    }
}

@main struct ComposerProbe {
    @MainActor static func main() {
        let inspect = CommandLine.arguments.contains("--inspect")
        NSApplication.shared.setActivationPolicy(inspect ? .accessory : .prohibited)
        let state = ComposerState()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Corral composer continuity verification"
        let host = NSHostingView(rootView: AnyView(ComposerScreen(state: state)))
        window.contentView = host
        // Never activate the app or move the user's pointer.
        window.orderBack(nil)
        defer { window.close() }
        let document = MacConversationTextDocument(), owner = NSObject()
        let style = MacConversationTextDocument.Style(font: .systemFont(ofSize: 14),
                                                      foreground: .labelColor, userForeground: .labelColor)
        var sources = [MacConversationTextDocument.Source(id: 1, text: "Streaming reply", isUser: false)]
        func render() {
            document.update(identity: ObjectIdentifier(owner), sources: sources, style: style) {
                NSAttributedString(string: $0.text, attributes: [.font: style.font])
            }
        }
        render()
        let message = NSTextView(frame: NSRect(x: 20, y: 130, width: 590, height: 80),
                                 textContainer: document.container(for: 1))
        message.isEditable = false
        host.addSubview(message)
        pump(host)
        guard let field = descendants(host).compactMap({ $0 as? NSTextField }).first(where: \.isEditable),
              window.makeFirstResponder(field) else { fatalError("No native composer") }
        pump(host)
        guard let editor = window.firstResponder as? NSTextView else { fatalError("No native field editor") }
        func replaceDraft(_ text: String) {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            pump(host)
            precondition(state.text == text, "Native edit failed to update the draft binding")
        }
        func refresh() {
            state.revision += 1
            // The streaming reply is the last source; earlier history may be
            // prepended during the run, so never assume index zero.
            sources[sources.count - 1] = .init(id: 1, text: "Streaming reply \(state.revision)", isUser: false)
            render()
            host.rootView = AnyView(ComposerScreen(state: state))
            pump(host)
        }
        func preserve(_ range: NSRange, label: String) {
            editor.setSelectedRange(range)
            pump(host)
            let text = editor.string
            for _ in 0..<8 {
                refresh()
                precondition(window.firstResponder === editor, "\(label): focus stolen")
                precondition(editor.string == text && state.text == text, "\(label): draft changed")
                precondition(editor.selectedRange() == range,
                             "\(label): caret moved from \(range) to \(editor.selectedRange())")
            }
            print("PASS \(label): \(range) after 8 production message updates")
        }
        replaceDraft("Draft 中文🙂 middle text")
        preserve(NSRange(location: (editor.string as NSString).length, length: 0), label: "end caret")
        preserve(NSRange(location: 6, length: 0), label: "middle caret")
        preserve(NSRange(location: 6, length: 4), label: "Unicode selection")
        sources.insert(.init(id: 0, text: "Earlier history", isUser: false), at: 0)
        render(); pump(host)
        precondition(editor.selectedRange() == NSRange(location: 6, length: 4), "Prepending history moved composer selection")
        replaceDraft("First line\nSecond 中文🙂 line\nThird line")
        preserve(NSRange(location: 16, length: 0), label: "multiline caret")
        editor.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: editor.selectedRange())
        pump(host)
        let marked = editor.markedRange(), caret = editor.selectedRange(), composed = editor.string
        for _ in 0..<8 {
            refresh()
            precondition(editor.hasMarkedText() && editor.markedRange() == marked, "Message update ended IME composition")
            precondition(editor.selectedRange() == caret && editor.string == composed, "Message update moved IME caret")
        }
        editor.unmarkText()
        print("PASS Chinese IME marked text after 8 production message updates")
        replaceDraft("Draft kept")
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                fatalError("No native key event")
            }
            window.sendEvent(event)
            pump(host)
        }
        key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.function, .numericPad])
        precondition(state.text == "Newest 中文🙂 prompt", "Up did not recall newest prompt")
        precondition(editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0), "Recall caret is not at end")
        key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.function, .numericPad])
        precondition(state.text == "Draft kept", "Down did not restore draft")
        editor.setSelectedRange(NSRange(location: 5, length: 0)); pump(host)
        key(36, "\r", modifiers: [.shift])
        precondition(state.text == "Draft\n kept" && editor.selectedRange() == NSRange(location: 6, length: 0),
                     "Shift-Return did not insert at native caret")
        precondition(state.sends == 0, "Inspection sent a prompt")
        print("PASS native Up/Down recall, draft restoration and Shift-Return; no sends")
        if inspect {
            replaceDraft("Keep typing 中文🙂 right here while messages arrive")
            preserve(NSRange(location: 12, length: 0), label: "visible native composer")
            for _ in 0..<60 { refresh() }
        }
    }

    @MainActor static func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
