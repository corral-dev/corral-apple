import AppKit
import SwiftUI
import Observation

@Observable @MainActor final class ReflowState {
    var scale: CGFloat = 1
    var jump: String?
    var linked = false
}

/// Product text, layout and activity controls; only data/detail services are fixtures.
private struct ReflowScreen: View {
    let state: ReflowState
    let owner: NSObject
    let messages: [RichMessage]

    var body: some View {
        ChatScrollView(scrollToLatestRequest: 0, latestID: "message-\(messages.count)",
                       scrollToMessageID: Binding(get: { state.jump }, set: { state.jump = $0 }),
                       header: { EmptyView() }) {
            ForEach(messages, id: \.seq) { message in
                VStack(alignment: .leading, spacing: 8) {
                    if message.seq == messages.count - 1 {
                        ToolActivityView(tools: [.init(id: "fixture-tool")], sourceSeqs: [message.seq], runtimeID: "codex")
                    }
                    SelectableAttributedText(attributed: AttributedString(message.text ?? ""))
                        .environment(\.macMessageSelectionID, message.seq)
                }
                .id("message-\(message.seq)")
            }
        }
        .modifier(MacConversationTextSelection(identity: ObjectIdentifier(owner), messages: messages))
        .environment(\.interfaceScale, state.scale)
    }
}

private struct UpdatedTextScreen: View {
    let state: ReflowState
    var body: some View {
        var text = AttributedString("Unchanged words with updated attributes")
        if state.linked { text.link = URL(string: "https://example.com/updated") }
        return SelectableAttributedText(attributed: text)
    }
}

@main
struct ReflowProbe {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--inspect") {
            inspectWindow()
            return
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkAttributeUpdate()
        checkConversation(count: 3)
        checkConversation(count: 120)
        print("PASS native capsule hit targets, short/long zoom and width reflow, drawn text ranges, history position and native selection")
    }

    @MainActor static func checkAttributeUpdate() {
        let state = ReflowState()
        let host = NSHostingView(rootView: UpdatedTextScreen(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        pump(host)
        state.linked = true
        pump(host)
        let text = descendants(host).compactMap { $0 as? NSTextView }.first
        precondition(text?.textStorage?.attribute(.link, at: 0, effectiveRange: nil) != nil,
                     "Same-string attribute update never reached the drawn text storage")
    }

    @MainActor static func inspectWindow() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let state = ReflowState(), owner = NSObject()
        state.scale = CommandLine.arguments.contains("--large") ? 1.5 : 1
        let messages = (1...3).map {
            RichMessage(seq: $0, text: "Message \($0). 中文 text remains drawn after zoom. "
                + String(repeating: "Native selectable conversation text. ", count: 3), role: "assistant")
        }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Corral activity and zoom verification"
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ReflowScreen(state: state, owner: owner, messages: messages)
            .tint(Color(red: 0.27, green: 0.48, blue: 0.36))
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFront(nil)
        pump(host, seconds: 1)
        if CommandLine.arguments.contains("--popover"),
           let button = descendants(host).compactMap({ $0 as? NSButton }).first {
            button.performClick(nil)
        }
        pump(host, seconds: 45)
        window.close()
    }

    @MainActor static func checkConversation(count: Int) {
        let state = ReflowState(), owner = NSObject()
        let messages = (1...count).map { index in
            RichMessage(seq: index,
                        text: "Message \(index). " + String(repeating: "中文 layout text. ", count: count > 3 && index.isMultiple(of: 3) ? 100 : 8),
                        role: "assistant")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ReflowScreen(state: state, owner: owner, messages: messages))
        window.contentView = host
        pump(host)
        var checkedButtons = 0
        for (width, scale) in [(600.0, 1.0), (600, 1.5), (420, 0.8), (760, 1.5), (600, 1.0)] {
            state.scale = scale
            window.setContentSize(NSSize(width: width, height: 480))
            pump(host)
            let texts = descendants(host).compactMap { $0 as? NSTextView }
                .filter { !$0.isEditable && !$0.visibleRect.isEmpty }
            precondition(!texts.isEmpty, "Zoom/resize left no visible native conversation text")
            for text in texts {
                guard let container = text.textContainer, let layout = text.layoutManager else {
                    preconditionFailure("Message lost its native text network")
                }
                let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
                precondition(glyphs.length > 0, "Visible message has no drawable glyphs after reflow")
                let used = layout.usedRect(for: container)
                precondition(used.maxY <= text.bounds.height + 1,
                             "Text exceeds allocated row: used=\(used) bounds=\(text.bounds) count=\(count) width=\(width) scale=\(scale)")
            }
            let lastVisible = texts.contains { text in
                guard let container = text.textContainer, let layout = text.layoutManager else { return false }
                let range = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
                let lastStart = (text.string as NSString).range(of: "Message \(count).").location
                return lastStart != NSNotFound && NSLocationInRange(lastStart, range)
            }
            precondition(lastVisible, "Following latest lost its final message during reflow")
            for button in descendants(host).compactMap({ $0 as? NSButton }) where !button.visibleRect.isEmpty {
                // The mounted fixture has only one native activity button. Its
                // full capsule must resolve to it rather than a neighboring text view.
                guard button.bounds.height < 50 else { continue }
                // Following the final message can clip the preceding capsule.
                // Reveal it before testing every point, including its edges.
                button.scrollToVisible(button.bounds)
                pump(host)
                let frame = button.convert(button.bounds, to: host)
                precondition(button.visibleRect.contains(button.bounds), "Capsule fixture is still clipped")
                for x in [0.1, 0.5, 0.9] {
                    for y in [0.1, 0.5, 0.9] {
                        let point = NSPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
                        guard host.bounds.contains(point) else { continue }
                        let hit = host.hitTest(host.convert(point, to: host.superview))
                        precondition(hit === button || hit?.isDescendant(of: button) == true,
                                     "Capsule point \(point) frame=\(frame) hit=\(String(describing: hit)) at \(count) messages / \(scale) / \(width)")
                        checkedButtons += 1
                    }
                }
            }
            state.jump = "message-\(count)"
            pump(host)
        }
        precondition(checkedButtons >= 18, "Native capsule was not tested at multiple sizes")
        if count > 3 {
            state.jump = "message-60"
            pump(host, seconds: 0.8)
            guard let text = descendants(host).compactMap({ $0 as? NSTextView }).first(where: { !$0.visibleRect.isEmpty }) else {
                preconditionFailure("History jump has no visible text")
            }
            let selection = NSRange(location: (text.string as NSString).range(of: "Message 60.").location, length: 10)
            precondition(selection.location != NSNotFound)
            window.makeFirstResponder(text)
            text.setSelectedRange(selection)
            for scale in [0.8, 1.5, 1.0] {
                state.scale = scale
                pump(host)
                let live = descendants(host).compactMap { $0 as? NSTextView }.filter { !$0.visibleRect.isEmpty }
                precondition(!live.isEmpty && live.allSatisfy { $0.selectedRange() == selection },
                             "Reflow cleared the shared native text selection")
                precondition(live.contains { view in
                    guard let layout = view.layoutManager, let container = view.textContainer else { return false }
                    let range = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
                    return NSLocationInRange(selection.location, range)
                }, "Zoom jumped away from the selected history message")
            }
        }
    }

    @MainActor static func pump(_ host: NSView, seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
