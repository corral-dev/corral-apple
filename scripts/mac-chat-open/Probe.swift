import AppKit
import SwiftUI
import Observation

@Observable @MainActor final class OpenState {
    var messages: [RichMessage] = []
    var scale: CGFloat = 1
    var jump: String?
}

/// Mirrors `MacPaneHostingView`: dormant panes defer layout until revealed.
final class DeferringHost: NSHostingView<AnyView> {
    private var deferred = false
    override func layout() {
        if isHidden { deferred = true; return }
        super.layout()
    }
    override var isHidden: Bool {
        didSet { if !isHidden, deferred { deferred = false; needsLayout = true } }
    }
}

/// The production scroll view and native text network; the loading branch
/// mirrors `ChatView` (the list mounts when the first window arrives).
private struct OpenScreen: View {
    let state: OpenState
    let owner: NSObject

    var body: some View {
        if let last = state.messages.last {
            ChatScrollView(scrollToLatestRequest: 0, latestID: "message-\(last.seq)",
                           scrollToMessageID: Binding(get: { state.jump }, set: { state.jump = $0 }),
                           header: { Color.clear.frame(height: 44) }) {
                ForEach(state.messages, id: \.seq) { message in
                    SelectableAttributedText(attributed: AttributedString(message.text ?? ""))
                        .environment(\.macMessageSelectionID, message.seq)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.15)))
                        .padding(.top, message.seq.isMultiple(of: 2) ? 8 : 0)
                        .id("message-\(message.seq)")
                }
            }
            .modifier(MacConversationTextSelection(identity: ObjectIdentifier(owner), messages: state.messages))
            .environment(\.interfaceScale, state.scale)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Mixed short and very long replies, so estimated and measured heights differ.
func makeMessages(_ range: ClosedRange<Int>) -> [RichMessage] {
    range.map { index in
        let repeats = [1, 3, 40, 6, 120, 2, 15][index % 7]
        let markdown = index.isMultiple(of: 3) ? "\n\n## Heading 中文\n\n- **Bold** list entry\n- Second entry\n\n| Key | Description |\n|---|---|\n| 中文 | A longer cell that wraps across several lines in a narrow split pane |\n| Path | `some/path/file.swift` |\n\n```swift\nlet value = 123\nprint(value)\n```" : ""
        return RichMessage(seq: index,
                           text: "Message \(index). " + String(repeating: "中文 conversation text with some words. ", count: repeats) + markdown,
                           role: index.isMultiple(of: 2) ? "user" : "assistant")
    }
}

/// Opening a conversation while following the latest message: the first
/// window, a live append, a wholesale window replacement (cached tail, then
/// the host's newer window) and an older-page prepend, in visible and
/// revealed-dormant hosts. Every display frame after the change must show
/// the latest message; a blank viewport (no drawn row) fails.
@main
struct OpenProbe {
    static var failures: [String] = []
    static var transientFrames = 0

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for width in [520.0, 900.0] {
            for hidden in [false, true] { run(width: width, hidden: hidden) }
        }
        if !failures.isEmpty {
            print(failures.joined(separator: "\n"))
            print("FAIL \(failures.count) blank or stale viewports")
            exit(1)
        }
        print("PASS conversation open, append, window replacement and prepend keep the latest rows drawn (\(transientFrames) pre-display transient states)")
    }

    @MainActor static func run(width: CGFloat, hidden: Bool) {
        let state = OpenState(), owner = NSObject()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = DeferringHost(rootView: AnyView(OpenScreen(state: state, owner: owner)))
        host.sizingOptions = []
        let mount = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 640))
        host.frame = mount.bounds
        host.autoresizingMask = [.width, .height]
        mount.addSubview(host)
        window.contentView = mount
        window.orderFront(nil)
        pump(0.3)
        let tag = "width \(Int(width))\(hidden ? " revealed" : "")"
        let steps: [(String, ClosedRange<Int>)] = [
            ("open", 1...150), ("append", 1...170), ("window", 90...260), ("prepend", 40...260),
        ]
        for (step, entry) in (steps + steps).enumerated() {
            let (name, range) = entry
            if hidden { host.isHidden = true }
            state.messages = makeMessages(range)
            state.scale = [1.0, 1.5, 0.8, 1.2][step % 4]
            window.setContentSize(NSSize(width: step.isMultiple(of: 2) ? width : width * 0.7, height: 640))
            if hidden { pump(0.2); host.isHidden = false }
            pump(0.001)
            if drawnRows(host).latest != range.upperBound { transientFrames += 1 }
            // One display frame, then settled states.
            for (delay, label) in [(0.016, "first frame"), (0.3, "settled"), (0.5, "later")] {
                pump(delay)
                let rows = drawnRows(host)
                checkFrames(host, tag: "\(tag) \(name) \(label)")
                if rows.latest != range.upperBound {
                    failures.append("\(tag) \(name) \(label): drawn rows \(rows.count), latest \(rows.latest ?? -1), expected \(range.upperBound)")
                }
            }
        }
    }

    @MainActor static func checkFrames(_ host: NSView, tag: String) {
        let texts = descendants(host).compactMap { $0 as? NSTextView }
            .filter { !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor }
        for text in texts {
            guard let layout = text.layoutManager, let container = text.textContainer else { continue }
            let used = layout.usedRect(for: container)
            if used.maxY > text.bounds.height + 1 {
                failures.append("\(tag): text overflows row: used=\(used.maxY) height=\(text.bounds.height)")
            }
        }
        let frames = texts.map { $0.convert($0.bounds, to: host) }.sorted { $0.minY < $1.minY }
        for pair in zip(frames, frames.dropFirst()) where pair.0.maxY > pair.1.minY + 1 {
            failures.append("\(tag): overlapping text frames \(pair)")
        }
    }

    /// Rows whose native glyphs intersect the conversation viewport, and the
    /// highest message number among them.
    @MainActor static func drawnRows(_ host: NSView) -> (count: Int, latest: Int?) {
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView })
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView else { return (0, nil) }
        let visible = document.visibleRect
        var numbers: [Int] = []
        for text in descendants(document).compactMap({ $0 as? NSTextView }) {
            guard text.convert(text.bounds, to: document).intersects(visible), !text.isHiddenOrHasHiddenAncestor,
                  let layout = text.layoutManager, let container = text.textContainer else { continue }
            // Every view shares one storage; attribute rows through their own container.
            let own = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
            guard layout.glyphRange(forBoundingRect: text.visibleRect, in: container).length > 0,
                  own.length > 0 else { continue }
            let prefix = (text.string as NSString).substring(with: NSRange(location: own.location, length: min(own.length, 16)))
            let words = prefix.split(separator: " ")
            if words.count > 1, let number = Int(words[1].trimmingCharacters(in: .punctuationCharacters)) {
                numbers.append(number)
            }
        }
        return (numbers.count, numbers.max())
    }

    @MainActor static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
