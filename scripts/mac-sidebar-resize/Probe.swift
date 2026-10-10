import AppKit
import SwiftUI

private struct ConversationFixture: View {
    let owner: NSObject
    let messages: [RichMessage]

    var body: some View {
        ChatScrollView(scrollToLatestRequest: 0, latestID: "message-\(messages.count)",
                       scrollToMessageID: .constant(nil), header: { EmptyView() }) {
            ForEach(messages, id: \.seq) { message in
                SelectableAttributedText(attributed: AttributedString(message.text ?? ""))
                    .environment(\.macMessageSelectionID, message.seq)
                    .id("message-\(message.seq)")
            }
        }
        .modifier(MacConversationTextSelection(identity: ObjectIdentifier(owner), messages: messages))
    }
}

private struct SplitFixture: View {
    let owners: [NSObject]
    let messages: [RichMessage]
    let workspace: MacWorkspace

    var body: some View {
        EqualPanes {
            ForEach(owners.indices, id: \.self) { index in
                ConversationFixture(owner: owners[index], messages: messages)
                    .containerValue(\.macPaneKey, "pane-\(index)")
            }
        }
        .environment(workspace)
    }
}

@main struct SidebarResizeProbe {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var results: [[String: Any]] = []
        for count in [3, 120] {
            for panes in [1, 2, 4] {
                results.append(measure(messages: count, panes: panes))
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(String(decoding: data, as: UTF8.self))
    }

    @MainActor static func measure(messages count: Int, panes: Int) -> [String: Any] {
        let messages = (1...count).map { index in
            RichMessage(seq: index, text: "Message \(index). " + String(repeating: "中文 layout text. ", count: index.isMultiple(of: 3) ? 100 : 8), role: "assistant")
        }
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1800, height: 640))
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 640)))
        let host = NSHostingView(rootView: SplitFixture(owners: (0..<panes).map { _ in NSObject() },
                                                      messages: messages, workspace: MacWorkspace()))
        split.addArrangedSubview(host)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        defer { window.close() }
        split.setPosition(260, ofDividerAt: 0)
        pump(host, seconds: 1)
        var timings: [Double] = []
        for iteration in 0..<60 {
            let start = ContinuousClock.now
            let position = 260 + CGFloat(iteration < 30 ? iteration : 59 - iteration) * 4
            split.setPosition(position, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            host.layoutSubtreeIfNeeded()
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        pump(host, seconds: 0.2)
        let texts = descendants(host).compactMap { $0 as? NSTextView }.filter { !$0.visibleRect.isEmpty }
        precondition(texts.count >= panes, "Resize left an empty conversation pane")
        for text in texts {
            guard let layout = text.layoutManager, let container = text.textContainer else { preconditionFailure("Missing text network") }
            precondition(layout.glyphRange(forBoundingRect: text.visibleRect, in: container).length > 0,
                         "Resize left visible text without glyphs")
        }
        let sorted = timings.sorted()
        return ["messages": count, "panes": panes, "steps": timings.count,
                "medianMs": sorted[sorted.count / 2], "p95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                "maxMs": sorted.last ?? 0, "totalMs": timings.reduce(0, +)]
    }

    @MainActor static func pump(_ host: NSView, seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
