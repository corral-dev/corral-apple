#if os(macOS)
import AppKit

/// One native text network per conversation. Each message is a separate text
/// container, like a page in an AppKit document, with a shared selection.
@MainActor
final class MacConversationTextDocument: NSObject, @MainActor NSLayoutManagerDelegate {
    struct Source: Equatable {
        let id: Int
        let text: String
        let isUser: Bool
    }

    struct Style: Equatable {
        let font: NSFont
        let foreground: NSColor
        let userForeground: NSColor
    }

    static let initialCanvasHeight: CGFloat = 100_000

    private final class Block {
        // AppKit ignores explicit container breaks with a near-infinite height.
        // Use a finite canvas; the representable grows it for unusually tall text.
        let container = NSTextContainer(size: NSSize(width: 760, height: MacConversationTextDocument.initialCanvasHeight))
        var source: Source
        var text: NSAttributedString
        var range = NSRange(location: 0, length: 0)
        var view: NSTextView?

        init(source: Source, text: NSAttributedString) {
            self.source = source
            self.text = text
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
        }
    }

    private struct Position {
        let id: Int
        let offset: Int
    }

    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    private var identity: ObjectIdentifier?
    private var sources: [Source] = []
    private var style: Style?
    private var blocks: [Block] = []
    private var byID: [Int: Block] = [:]
    private var breaks: Set<Int> = []

    override init() {
        super.init()
        storage.addLayoutManager(layout)
        layout.delegate = self
    }

    /// Only changed messages are rendered. Containers for unloaded SwiftUI rows
    /// stay in the network, so lazy realization cannot reorder or omit text.
    func update(
        identity: ObjectIdentifier,
        sources: [Source],
        style: Style,
        render: (Source) -> NSAttributedString
    ) {
        guard self.identity != identity || self.sources != sources || self.style != style else { return }
        let sameConversation = self.identity == identity
        let selection = sameConversation ? layout.firstTextView?.selectedRange() : nil
        let start = selection.flatMap { position(at: $0.location) }
        let end = selection.flatMap { position(at: NSMaxRange($0)) }
        let oldByID = sameConversation ? byID : [:]
        let styleChanged = self.style != style
        let oldRanges = blocks.map(\.range)
        var changedIDs: Set<Int> = []
        let next = sources.map { source -> Block in
            if let existing = oldByID[source.id] {
                if existing.source != source || styleChanged {
                    changedIDs.insert(source.id)
                    existing.source = source
                    existing.text = render(source)
                }
                return existing
            }
            return Block(source: source, text: render(source))
        }

        // A message-separator newline starts the next container. It remains an
        // ordinary newline on the pasteboard, with no private marker to strip.
        let combined = NSMutableAttributedString(string: "")
        breaks.removeAll(keepingCapacity: true)
        for (index, block) in next.enumerated() {
            block.range = NSRange(location: combined.length, length: block.text.length)
            combined.append(block.text)
            if index < next.count - 1 {
                breaks.insert(combined.length)
                combined.append(NSAttributedString(string: "\n", attributes: [.font: style.font]))
            }
        }

        let sameOrder = blocks.elementsEqual(next, by: { $0 === $1 })
        if !sameOrder {
            for index in layout.textContainers.indices.reversed() {
                layout.removeTextContainer(at: index)
            }
            for block in next { layout.addTextContainer(block.container) }
        }
        blocks = next
        byID = Dictionary(uniqueKeysWithValues: next.map { ($0.source.id, $0) })
        self.identity = identity
        self.sources = sources
        self.style = style
        if sameOrder, !styleChanged,
           let first = next.firstIndex(where: { changedIDs.contains($0.source.id) }),
           let last = next.lastIndex(where: { changedIDs.contains($0.source.id) }) {
            // Retain layout before a streaming edit instead of invalidating the
            // entire loaded conversation for every token batch.
            let old = NSRange(location: oldRanges[first].location,
                              length: NSMaxRange(oldRanges[last]) - oldRanges[first].location)
            let updated = NSRange(location: next[first].range.location,
                                  length: NSMaxRange(next[last].range) - next[first].range.location)
            storage.replaceCharacters(in: old, with: combined.attributedSubstring(from: updated))
        } else {
            storage.setAttributedString(combined)
        }
        if styleChanged {
            // Lazy rows retain their native views. Redraw them after typography
            // reflows even when their SwiftUI wrapper keeps the same frame.
            for block in next { block.view?.needsDisplay = true }
        }
        if let start, let end, let lower = index(of: start), let upper = index(of: end), upper >= lower {
            layout.firstTextView?.setSelectedRange(NSRange(location: lower, length: upper - lower))
        } else {
            layout.firstTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func container(for id: Int) -> NSTextContainer? { byID[id]?.container }

    /// Stable native members of one coordinated TextKit network. SwiftUI's
    /// lazy rows may retire and realize independently of the loaded messages.
    func textView(for id: Int) -> NSTextView? {
        guard let block = byID[id] else { return nil }
        if let view = block.view { return view }
        let view = NSTextView(frame: .zero, textContainer: block.container)
        block.view = view
        return view
    }

    func range(for id: Int) -> NSRange? { byID[id]?.range }

    func text(for id: Int) -> NSAttributedString? { byID[id]?.text }

    /// Transfer focus before a lazy row leaves the native hierarchy. Let the
    /// native text view retire its own TextKit coordination during destruction:
    /// manual container disconnection leaves a stale selection cache on macOS 27.
    static func retireTextView(_ view: NSTextView) {
        // NSWindow does not own its responder. A lazy row can leave the native
        // hierarchy while an inspection/selection still retains its text view.
        // Retire its focus while the object is valid, preferring a live sibling
        // in the same conversation so the shared selection keeps native Copy.
        if let window = view.window ?? NSApp.windows.first(where: { $0.firstResponder === view }),
           window.firstResponder === view {
            let sibling = view.layoutManager?.textContainers.compactMap(\.textView).first {
                $0 !== view && $0.window === window && !$0.visibleRect.isEmpty
            }
            window.makeFirstResponder(sibling)
        }
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        breaks.contains(charIndex) ? .containerBreak : action
    }

    private func position(at index: Int) -> Position? {
        guard index != NSNotFound else { return nil }
        guard let block = blocks.first(where: { index >= $0.range.location && index <= NSMaxRange($0.range) }) else {
            return nil
        }
        return Position(id: block.source.id, offset: index - block.range.location)
    }

    private func index(of position: Position) -> Int? {
        guard let block = byID[position.id] else { return nil }
        return block.range.location + min(position.offset, block.range.length)
    }
}
#endif
