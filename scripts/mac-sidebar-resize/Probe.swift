import AppKit
import SwiftUI
import Darwin

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
    var baseline: Bool

    var body: some View {
        Group {
            #if RESIZE_BASELINE
            if baseline {
                BaselineEqualPanes { contents }
            } else {
                EqualPanes { contents }
            }
            #else
            EqualPanes { contents }
            #endif
        }
        .environment(workspace)
    }

    private var contents: some View {
        ForEach(owners.indices, id: \.self) { index in
            ConversationFixture(owner: owners[index], messages: messages)
                .containerValue(\.macPaneKey, "pane-\(index)")
        }
    }
}

@main struct SidebarResizeProbe {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkMeasurementLifetime()
        var results: [[String: Any]] = []
        let environment = ProcessInfo.processInfo.environment
        let counts = Int(environment["CORRAL_RESIZE_MESSAGES"] ?? "").map { [$0] } ?? [3, 120]
        let paneCounts = Int(environment["CORRAL_RESIZE_PANES"] ?? "").map { [$0] } ?? [1, 2, 4]
        for count in counts {
            for panes in paneCounts {
                #if RESIZE_BASELINE
                results.append(measure(messages: count, panes: panes, baseline: true))
                #endif
                results.append(measure(messages: count, panes: panes, baseline: false))
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(String(decoding: data, as: UTF8.self))
    }

    @MainActor static func checkMeasurementLifetime() {
        let document = MacConversationTextDocument(), owner = NSObject()
        let font = NSFont.systemFont(ofSize: 13)
        let style = MacConversationTextDocument.Style(font: font, foreground: .labelColor, userForeground: .labelColor)
        let sources = (1...40).map { MacConversationTextDocument.Source(id: $0, text: "Message \($0)", isUser: false) }
        func update(_ sources: [MacConversationTextDocument.Source]) {
            document.update(identity: ObjectIdentifier(owner), sources: sources, style: style) {
                NSAttributedString(string: $0.text, attributes: [.font: font])
            }
        }
        update(sources)
        var first = document.measurement(for: 1)
        weak let retired = first
        precondition(first === document.measurement(for: 1), "Lazy reattachment discarded message measurement")
        let short = first!.size(for: document.text(for: 1)!, font: font, width: 120)
        let longText = NSAttributedString(string: String(repeating: "中文 streaming text. ", count: 120), attributes: [.font: font])
        let long = first!.size(for: longText, font: font, width: 120)
        precondition(long.height > short.height, "Changed source reused a stale size")
        let narrow = first!.size(for: longText, font: font, width: 80)
        precondition(narrow.height > long.height, "Width reflow reused stale geometry")
        precondition(first!.size(for: longText, font: font, width: 120) == long, "Returning width changed text geometry")
        first = nil
        for id in 2...40 { _ = document.measurement(for: id) }
        precondition(retired == nil, "Detached measurements grew beyond the recent working set")
        weak let removed = document.measurement(for: 40)
        update(Array(sources.prefix(2)))
        precondition(removed == nil, "Removed history retained detached text layout")
        let replacement = MacConversationTextDocument()
        replacement.update(identity: ObjectIdentifier(owner), sources: sources, style: style) {
            NSAttributedString(string: $0.text, attributes: [.font: font])
        }
        precondition(document.measurement(for: 1) !== replacement.measurement(for: 1), "Panes shared measurement ownership")
    }

    @MainActor static func measure(messages count: Int, panes: Int, baseline: Bool) -> [String: Any] {
        let messages = (1...count).map { index in
            RichMessage(seq: index, text: "Message \(index). " + String(repeating: "中文 layout text. ", count: index.isMultiple(of: 3) ? 100 : 8), role: "assistant")
        }
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1800, height: 640))
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 640)))
        let host = NSHostingView(rootView: SplitFixture(owners: (0..<panes).map { _ in NSObject() },
                                                      messages: messages, workspace: MacWorkspace(), baseline: baseline))
        split.addArrangedSubview(host)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        defer { window.close() }
        split.setPosition(260, ofDividerAt: 0)
        pump(host, seconds: 1)
        if ProcessInfo.processInfo.environment["CORRAL_RESIZE_NONCONTIGUOUS"] == "1" {
            for text in descendants(host).compactMap({ $0 as? NSTextView }) {
                text.layoutManager?.allowsNonContiguousLayout = true
            }
        }
        var timings: [Double] = []
        var cpuTimings: [Double] = []
        let steps = Int(ProcessInfo.processInfo.environment["CORRAL_RESIZE_STEPS"] ?? "") ?? 60
        for iteration in 0..<steps {
            let start = ContinuousClock.now
            let cpuStart = cpuMilliseconds()
            let phase = iteration % 60
            let position = 260 + CGFloat(phase < 30 ? phase : 59 - phase) * 4
            split.setPosition(position, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            host.layoutSubtreeIfNeeded()
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            cpuTimings.append(cpuMilliseconds() - cpuStart)
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
        let sortedCPU = cpuTimings.sorted()
        return ["layout": baseline ? "baseline" : "current", "messages": count, "panes": panes, "steps": timings.count,
                "medianMs": sorted[sorted.count / 2], "p95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                "maxMs": sorted.last ?? 0, "totalMs": timings.reduce(0, +),
                "medianCPUMs": sortedCPU[sortedCPU.count / 2], "totalCPUMs": cpuTimings.reduce(0, +)]
    }

    nonisolated static func cpuMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    @MainActor static func pump(_ host: NSView, seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
