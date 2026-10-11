import AppKit
import SwiftUI
import Observation

/// Fixture model driving the pooled list directly (no stores, no host).
@Observable @MainActor final class PooledListState {
    var scale: CGFloat = 1
    var messages: [RichMessage] = []
    var jump: String?
    var latestRequest = 0
    var earlierLoads = 0
    var follows = true
}

private struct PooledListScreen: View {
    @Bindable var state: PooledListState
    let owner: NSObject
    let document: MacConversationTextDocument

    private var rows: [MacPooledRow] {
        var rows = state.messages.map { MacPooledRow.timeline(.message($0)) }
        rows.append(.prompts)
        rows.append(.activity)
        return rows
    }

    private var prompts: [SessionPrompt] {
        [SessionPrompt(id: "q1", name: "tool", summary: "Pick one", detail: nil, options: ["One"])]
    }

    var body: some View {
        // Keep the shared text network in step, like MacConversationTextSelection.
        let sources = state.messages.compactMap { message -> MacConversationTextDocument.Source? in
            guard let text = message.text, !text.allSatisfy(\.isWhitespace) else { return nil }
            return .init(id: message.seq, text: text, isUser: message.role.lowercased() == "user")
        }
        let font = Typography.sessionUIFont(.bubbleBody, scale: state.scale)
        let style = MacConversationTextDocument.Style(
            font: font, foreground: .labelColor, userForeground: .white)
        document.update(identity: ObjectIdentifier(owner), sources: sources, style: style) { source in
            NSAttributedString(ChatMarkdown.attributed(source.text))
        }
        return MacPooledConversationList(
            rows: rows,
            separators: [:],
            gaps: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, 8.0) }),
            prompts: prompts,
            activity: .working,
            runtimeID: "codex",
            onQuestionSubmit: { _, _ in },
            onRetryMessage: { _ in },
            onNeedDetails: { _ in nil },
            interfaceScale: state.scale,
            sessionTextScale: 1,
            colorScheme: .light,
            document: document,
            onNeedEarlier: {
                state.earlierLoads += 1
                return false
            },
            scrollToMessageID: Binding(get: { state.jump }, set: { state.jump = $0 }),
            scrollToLatestRequest: state.latestRequest,
            onFollowChange: { state.follows = $0 }
        )
        .environment(\.interfaceScale, state.scale)
    }
}

@main
struct PooledListProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        isolatedBubbleCheck()
        checkPooledConversation(count: 120)
        print("PASS pooled conversation list: reuse, selection, jump, top load, reflow")
    }

    /// One bubble straight in a hosting view: isolates row content from table reuse.
    @MainActor static func isolatedBubbleCheck() {
        let owner = NSObject()
        let document = MacConversationTextDocument()
        let message = RichMessage(seq: 111, role: "assistant", text: "ISOLATED one-one-one bubble text here")
        document.update(identity: ObjectIdentifier(owner),
                        sources: [.init(id: 111, text: message.text ?? "", isUser: false)],
                        style: MacConversationTextDocument.Style(font: NSFont.systemFont(ofSize: 14), foreground: .labelColor, userForeground: .white)) { source in
            NSAttributedString(string: source.text)
        }
        let view = NSHostingView(rootView:
            MessageBubbleView(message: message, runtimeID: "codex")
                .environment(\.macMessageSelectionID, 111)
                .environment(\.macConversationTextDocument, document)
                .frame(width: 500, height: 200))
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        view.layoutSubtreeIfNeeded()
        let texts = ([view] + view.subviews.flatMap(descendants)).compactMap { $0 as? NSTextView }
    }

    /// Which message sequences a text view currently displays: resolved
    /// through its own container's laid-out glyphs, never through the shared
    /// storage string (every view in the network shares one storage, so
    /// `view.string` is the whole conversation for all of them).
    @MainActor static func displayedSeqs(of view: NSTextView, document: MacConversationTextDocument) -> [Int] {
        guard let container = view.textContainer, let layout = view.layoutManager else { return [] }
        let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        guard glyphs.length > 0 else { return [] }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var seqs: [Int] = []
        for id in 1...500 {
            guard let range = document.range(for: id) else { continue }
            if NSIntersectionRange(range, chars).length > 0 { seqs.append(id) }
            if range.location > NSMaxRange(chars) { break }
        }
        return seqs
    }

    @MainActor static func checkPooledConversation(count: Int) {
        let state = PooledListState()
        let owner = NSObject()
        let document = MacConversationTextDocument()
        state.messages = (1...count).map { index in
            RichMessage(seq: index, role: "assistant",
                        text: "Message \(index). " + String(repeating: "Native pooled conversation text. ", count: index.isMultiple(of: 3) ? 40 : 6))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PooledListScreen(state: state, owner: owner, document: document))
        window.contentView = host
        pump(host)

        // Visible rows draw glyphs and the latest message is laid out.
        // Attributed views share one storage, so row identity always comes
        // from each view's own container glyphs (see displayedSeqs), never
        // from view.string.
        func visibleViews() -> [NSTextView] {
            descendants(host).compactMap { $0 as? NSTextView }
                .filter { !$0.isEditable && !$0.visibleRect.isEmpty }
        }
        func seqs(of views: [NSTextView]) -> [Int: NSTextView] {
            var map: [Int: NSTextView] = [:]
            for view in views {
                if let seq = displayedSeqs(of: view, document: document).first {
                    map[seq] = view
                }
            }
            return map
        }
        var visible = visibleViews()
        precondition(!visible.isEmpty, "Pooled list shows no native conversation text")
        // Edge slivers (a few points of padding) legitimately hold no glyphs;
        // only substantially visible rows must draw.
        let substantial = visible.filter { $0.visibleRect.height >= 20 }
        precondition(!substantial.isEmpty, "Pooled list shows no substantially visible text")
        for text in substantial {
            guard let container = text.textContainer, let layout = text.layoutManager else {
                preconditionFailure("Pooled message lost its native text network")
            }
            let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
            precondition(glyphs.length > 0, "Visible pooled message has no drawable glyphs")
        }
        precondition(seqs(of: visible)[count] != nil,
                     "Pooled list did not land on the latest message")

        // Single-row edit reuses every other visible native view. The edited
        // row may grow, shifting the viewport: compare per message sequence
        // among rows visible both before and after.
        let beforeBySeq = seqs(of: visible)
        state.messages = state.messages.map { message in
            guard message.seq == count - 5 else { return message }
            var edited = message
            edited.text = (message.text ?? "") + " EDITED with enough extra words to wrap another line"
            return edited
        }
        pump(host)
        let afterViews = visibleViews()
        precondition(afterViews.contains { $0.string.contains("EDITED") }, "Edited pooled row did not update")
        let afterBySeq = seqs(of: afterViews)
        let shared = beforeBySeq.keys.filter { afterBySeq[$0] != nil && $0 != count - 5 }
        precondition(shared.count >= 3, "Too few comparable rows across the edit (\(shared.count))")
        let reused = shared.filter { afterBySeq[$0] === beforeBySeq[$0] }
        precondition(reused.count == shared.count,
                     "Pooled update recreated visible native views instead of reusing them (\(reused.count)/\(shared.count) reused)")

        // Jump lands on the requested history message.
        state.jump = "message-60"
        pump(host, seconds: 0.8)
        guard seqs(of: visibleViews())[60] != nil else {
            preconditionFailure("Pooled jump missed message-60")
        }

        // Selection survives a zoom reflow inside the shared network.
        guard let text = seqs(of: visibleViews())[60],
              let range60 = document.range(for: 60) else {
            preconditionFailure("Pooled jump left message-60 without a laid-out view")
        }
        let localStart = ((state.messages.first { $0.seq == 60 }?.text ?? "") as NSString).range(of: "Message 60.").location
        precondition(localStart != NSNotFound)
        let selection = NSRange(location: range60.location + localStart, length: 10)
        window.makeFirstResponder(text)
        text.setSelectedRange(selection)
        for scale in [0.8, 1.5, 1.0] {
            state.scale = scale
            pump(host)
            let live = visibleViews()
            guard let current = seqs(of: live)[60] else {
                preconditionFailure("Zoom lost the selected history message")
            }
            precondition(current.selectedRange() == selection,
                         "Reflow cleared pooled native text selection")
            guard let container = current.textContainer, let layout = current.layoutManager else {
                preconditionFailure("Selected pooled message lost its native text network")
            }
            let laidOut = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
            precondition(NSLocationInRange(selection.location, laidOut), "Zoom jumped away from the selected history message")
        }

        // Reading the top pages earlier through the same callback.
        state.scale = 1.0
        pump(host)
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first else {
            preconditionFailure("Pooled list has no scroll view")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)))
        pump(host, seconds: 0.8)
        precondition(state.earlierLoads >= 1, "Top proximity did not page earlier history")
        visible = visibleViews()
        for view in descendants(host).compactMap({ $0 as? NSTableView }) {
            for row in 0..<view.numberOfRows {
                guard let rowView = view.rowView(atRow: row, makeIfNecessary: false) else { continue }
                if !rowView.visibleRect.isEmpty {
                    precondition(rowView.frame.height > 20, "Pooled row has no measured height")
                }
            }
        }
        precondition(!visible.isEmpty, "Pooled list lost visible text after top load")
    }

    @MainActor static func pump(_ host: NSView, seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
