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
    var source = NSObject()
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
            detailSourceID: ObjectIdentifier(state.source),
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
        // The app's own text-network sync: same conversion, fonts and
        // per-conversation identity as ChatView.
        .modifier(MacConversationTextSelection(
            identity: ObjectIdentifier(state.source),
            messages: state.messages,
            documentOverride: document
        ))
        .environment(\.interfaceScale, state.scale)
    }
}

@main
struct PooledListProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        isolatedBubbleCheck()
        checkPooledConversation(count: 120)
        print("PASS pooled conversation list: follow latest, reuse, selection, jump, top load, reflow, fast scroll, switch")
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
        precondition(([view] + view.subviews.flatMap(descendants)).contains { $0 is NSTextView },
                     "Isolated bubble has no native text view")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
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
                .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
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
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let document0 = scroll.documentView else {
            preconditionFailure("Pooled list has no scroll view")
        }
        // NSTableView is flipped: the latest edge is the document's maxY.
        func distanceFromBottom() -> CGFloat {
            document0.frame.height - scroll.contentView.documentVisibleRect.maxY
        }
        precondition(state.follows, "Pooled list mounted at the latest edge but stopped following")
        precondition(distanceFromBottom() <= 1, "Pooled list did not mount pinned to the document end")

        // A following reader stays pinned while new messages stream in.
        for extra in 1...3 {
            let seq = count + extra
            state.messages.append(RichMessage(seq: seq, role: "assistant",
                text: "Streamed \(seq). " + String(repeating: "Fresh output keeps arriving. ", count: extra == 3 ? 30 : 4)))
            pump(host)
        }
        precondition(state.follows, "New messages turned off follow-latest")
        precondition(distanceFromBottom() <= 1,
                     "Pooled list fell off the latest edge as messages arrived (\(distanceFromBottom()) pt)")
        precondition(state.earlierLoads == 0, "Sitting at the latest edge paged earlier history")

        // Single-row edit reuses every other visible native view. The edited
        // row may grow, shifting the viewport: compare per message sequence
        // among rows visible both before and after.
        visible = visibleViews()
        let beforeBySeq = seqs(of: visible)
        guard let editedSeq = beforeBySeq.keys.sorted().dropLast().last else {
            preconditionFailure("Too few visible rows to edit (\(beforeBySeq.keys.sorted()))")
        }
        state.messages = state.messages.map { message in
            guard message.seq == editedSeq else { return message }
            var edited = message
            edited.text = (message.text ?? "") + " EDITED with enough extra words to wrap another line"
            return edited
        }
        pump(host)
        let afterViews = visibleViews()
        precondition(afterViews.contains { $0.string.contains("EDITED") }, "Edited pooled row did not update")
        let afterBySeq = seqs(of: afterViews)
        let shared = beforeBySeq.keys.filter { afterBySeq[$0] != nil && $0 != editedSeq }
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
        // The reader scrolls to the oldest edge (y = 0 in the flipped table).
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(host, seconds: 0.8)
        precondition(state.earlierLoads >= 1, "Top proximity did not page earlier history")
        precondition(!state.follows, "Reading the oldest messages still reports follow-latest")

        // New output must not yank a reader away from history.
        let readingOrigin = scroll.contentView.bounds.origin.y
        state.messages.append(RichMessage(seq: count + 10, role: "assistant", text: "Arrives while reading history"))
        pump(host)
        precondition(abs(scroll.contentView.bounds.origin.y - readingOrigin) < 1,
                     "A new message moved a reader who was reading history")

        // Jump to latest re-pins and resumes following.
        state.latestRequest += 1
        pump(host)
        precondition(state.follows, "Jump to latest did not resume following")
        precondition(distanceFromBottom() <= 1, "Jump to latest did not reach the document end")
        precondition(seqs(of: visibleViews())[count + 10] != nil, "Jump to latest missed the newest message")
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

        // Fast scrolling through the whole history: every displayed row shows
        // its own message and is never clipped by a stale row height.
        guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first else {
            preconditionFailure("Pooled list has no table")
        }
        func checkVisibleRows(_ phase: String) {
            for view in visibleViews() {
                var rowView: NSTableRowView?
                var cursor: NSView? = view
                while let current = cursor, rowView == nil {
                    rowView = current as? NSTableRowView
                    cursor = current.superview
                }
                guard let rowView else { continue }
                let row = table.row(for: rowView)
                guard state.messages.indices.contains(row) else { continue }
                let expected = state.messages[row].seq
                precondition(document.container(for: expected) === view.textContainer,
                             "\(phase): row \(row) shows another message's text (expected seq \(expected))")
                let frame = view.convert(view.bounds, to: rowView)
                precondition(frame.maxY <= rowView.bounds.height + 1,
                             "\(phase): row \(row) clips its text (\(frame.maxY) > \(rowView.bounds.height))")
            }
        }
        var y: CGFloat = 0
        while y < table.frame.height {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(host, seconds: 0.02)
            checkVisibleRows("Fast scroll at \(Int(y))")
            y += 900
        }
        pump(host)
        checkVisibleRows("Settled fast scroll")

        // Width changes (window resize, a pane revealed at another width, the
        // prompts card taking its margin) re-measure what is on screen.
        for width in [420.0, 760.0, 600.0] {
            window.setContentSize(NSSize(width: width, height: 800))
            pump(host)
            checkVisibleRows("Resized to \(Int(width))")
        }

        // Another conversation in the same list starts at its latest edge.
        state.source = NSObject()
        state.messages = (1...80).map { index in
            RichMessage(seq: index, role: index.isMultiple(of: 4) ? "user" : "assistant",
                        text: "Other \(index). " + String(repeating: "Switched conversation text. ", count: index.isMultiple(of: 5) ? 25 : 3))
        }
        pump(host, seconds: 0.6)
        precondition(state.follows, "Switching conversations kept the previous reading position")
        precondition(distanceFromBottom() <= 1,
                     "Switched conversation did not open at its latest edge (\(distanceFromBottom()) pt)")
        precondition(seqs(of: visibleViews())[80] != nil, "Switched conversation does not show its newest message")
        checkVisibleRows("Switched conversation")
    }

    @MainActor static func pump(_ host: NSView, seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
