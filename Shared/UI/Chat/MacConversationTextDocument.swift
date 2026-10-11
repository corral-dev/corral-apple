#if os(macOS)
import AppKit

#if DEBUG
/// Warm-switch diagnostics: do lazy text rows actually re-realize their native
/// views when returning to a retained pane, or only re-measure? Reset before
/// each inspected switch; the probe records the totals with its timing.
/// Main-thread only by construction (AppKit representable + @MainActor stores).
@MainActor
enum MacTextRowSwitchCounters {
    static var makes = 0
    static var dismantles = 0
    static var textSets = 0
    static var docEarlyReturns = 0
    static var docRenders = 0
    static func reset() {
        makes = 0
        dismantles = 0
        textSets = 0
        docEarlyReturns = 0
        docRenders = 0
    }
}
#endif

/// Uncapped Mac rows (the default: the conversation scrolls, not the bubble)
/// host their text view directly instead of inside a per-row scroll wrapper.
/// One `NSScrollView` + `NSClipView` pair per message laid out and drew on
/// every switch; with 80 messages × 4 panes that is hundreds of nested
/// scrollers for content that never scrolls itself. Wheel events forward to
/// the conversation scroll view, matching the wrapper's non-scrolling path.
final class MacDirectMessageTextView: NSTextView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    /// A plain press-and-drag selects across the conversation's message
    /// blocks. Word/paragraph clicks, modified clicks and links keep native
    /// handling.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let document = layoutManager?.delegate as? MacConversationTextDocument,
              !isLink(at: event) else {
            super.mouseDown(with: event)
            return
        }
        document.trackSelection(from: self, mouseDown: event)
    }

    private func isLink(at event: NSEvent) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let layout = layoutManager, let container = textContainer else { return false }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else {
            return false
        }
        let character = layout.characterIndexForGlyph(at: glyph)
        return character < storage.length && storage.attribute(.link, at: character, effectiveRange: nil) != nil
    }
}

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
    private var measurements: [Int: MacTextMeasurement] = [:]
    private var measurementOrder: [Int] = []

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
        #if DEBUG
        guard self.identity != identity || self.sources != sources || self.style != style else {
            MacTextRowSwitchCounters.docEarlyReturns &+= 1
            return
        }
        MacTextRowSwitchCounters.docRenders &+= 1
        #else
        guard self.identity != identity || self.sources != sources || self.style != style else { return }
        #endif
        let sameConversation = self.identity == identity
        if !sameConversation {
            measurements.removeAll()
            measurementOrder.removeAll()
        }
        let selection = sameConversation ? anyTextView?.selectedRange() : nil
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
        measurements = measurements.filter { byID[$0.key] != nil }
        measurementOrder.removeAll { byID[$0] == nil }
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
        // Lazy rows realize their views on demand, so the first container
        // often has none; the selection is shared by every view in the network.
        if let start, let end, let lower = index(of: start), let upper = index(of: end), upper >= lower {
            anyTextView?.setSelectedRange(NSRange(location: lower, length: upper - lower))
        } else {
            anyTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    /// Any view attached to this network: they all share one selection. The
    /// containers are the ground truth (rows realize views on demand, so the
    /// first container often has none); registered views are the fallback.
    private var anyTextView: NSTextView? {
        layout.textContainers.lazy.compactMap(\.textView).first ?? blocks.lazy.compactMap(\.view).first
    }

    /// Tracks a press-and-drag that began on `origin` until the button is
    /// released. AppKit's own cross-container tracking only reaches a block
    /// the window hit-tests at the pointer, so gaps, tool rows, overlays and
    /// rows recycled during autoscroll stopped it or jumped to the start of
    /// the conversation. Here every step resolves the pointer against the
    /// on-screen geometry of this conversation's blocks; AppKit still draws
    /// the selection and owns Copy.
    func trackSelection(from origin: NSTextView, mouseDown event: NSEvent) {
        guard let window = origin.window else { return }
        let scrollView = origin.enclosingScrollView
        let anchor = origin.characterIndexForInsertion(at: origin.convert(event.locationInWindow, from: nil))
        var current = anchor
        window.makeFirstResponder(origin)
        #if DEBUG
        Self.selectionTrace = [("anchor", anchor)]
        if let clip = scrollView?.contentView {
            Self.selectionTrace.append(("offDown", Int(clip.bounds.origin.y)))
            Self.selectionTrace.append(("frDown", Int(origin.convert(origin.bounds, to: nil).minY)))
        }
        #endif
        func select(_ index: Int, stillSelecting: Bool) {
            current = index
            let range = NSRange(location: min(anchor, index), length: abs(index - anchor))
            origin.setSelectedRange(range, affinity: index < anchor ? .upstream : .downstream,
                                    stillSelecting: stillSelecting)
        }
        select(anchor, stillSelecting: true)
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var pointer = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            switch next.type {
            case .leftMouseDragged:
                pointer = next.locationInWindow
            case .periodic:
                // Holding still past an edge keeps scrolling, like native text.
                guard let scrollView, Self.autoscroll(scrollView, toward: pointer) else { continue }
                #if DEBUG
                Self.selectionTrace.append(("scroll", Int(scrollView.contentView.bounds.origin.y)))
                #endif
            default:
                pointer = next.locationInWindow
                let routed = characterIndex(at: pointer, in: window, anchor: anchor)
                #if DEBUG
                Self.selectionTrace.append(("up", routed ?? -1))
                if let clip = scrollView?.contentView {
                    Self.selectionTrace.append(("offUp", Int(clip.bounds.origin.y)))
                    Self.selectionTrace.append(("frUp", Int(origin.convert(origin.bounds, to: nil).minY)))
                }
                #endif
                select(routed ?? current, stillSelecting: false)
                return
            }
            if next.type == .leftMouseDragged, let scrollView {
                if Self.autoscroll(scrollView, toward: pointer) {
                    #if DEBUG
                    Self.selectionTrace.append(("scroll", Int(scrollView.contentView.bounds.origin.y)))
                    #endif
                }
            }
            let routed = characterIndex(at: pointer, in: window, anchor: anchor)
            #if DEBUG
            Self.selectionTrace.append(("drag", routed ?? -1))
            #endif
            select(routed ?? current, stillSelecting: true)
        }
    }

    #if DEBUG
    /// Per-step routing trace of the in-progress drag inspection.
    static var selectionTrace: [(String, Int)] = []
    #endif

    /// The insertion index under a window point, resolved against the
    /// realized blocks of this conversation (top to bottom in reading order).
    /// Inside a block it is the native glyph boundary; between blocks it is
    /// the near edge seen from the anchor; above or below every realized block
    /// it is the outermost realized boundary, which autoscroll then extends.
    func characterIndex(at point: CGPoint, in window: NSWindow, anchor: Int) -> Int? {
        // Screen order, not document order: lazy rows realize top to bottom,
        // but the network must not assume the source array stays that way.
        let realized = blocks.compactMap { block -> (Block, NSTextView, CGRect)? in
            guard let view = block.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return (block, view, view.convert(view.bounds, to: nil))
        }.sorted { $0.2.maxY > $1.2.maxY }
        guard let last = realized.last else { return nil }
        for (index, (block, view, frame)) in realized.enumerated() {
            if point.y > frame.maxY {
                guard index > 0 else { return block.range.location }
                let previous = realized[index - 1].0
                return anchor <= NSMaxRange(previous.range) ? NSMaxRange(previous.range) : block.range.location
            }
            if point.y >= frame.minY {
                var local = view.convert(point, from: nil)
                local.x = min(max(local.x, 0), view.bounds.width)
                local.y = min(max(local.y, 0), max(view.bounds.height - 1, 0))
                let character = view.characterIndexForInsertion(at: local)
                return min(max(character, block.range.location), NSMaxRange(block.range))
            }
        }
        return NSMaxRange(last.0.range)
    }

    #if DEBUG
    /// The storage range of the block currently hosting a realized view.
    func range(of view: NSTextView) -> NSRange? {
        blocks.first { $0.view === view }?.range
    }

    /// One-shot drag-routing diagnostics for the selection inspection: the
    /// on-screen geometry of every realized block, the insertion index the
    /// pointer resolves to, and what the shared routing returns for it.
    func debugRoute(at point: CGPoint, in window: NSWindow) -> [String: Any] {
        var blocksInfo: [[String: Any]] = []
        let realized = blocks.compactMap { block -> (Block, NSTextView, CGRect)? in
            guard let view = block.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return (block, view, view.convert(view.bounds, to: nil))
        }
        for (block, view, frame) in realized {
            let local = view.convert(point, from: nil)
            let contains = view.bounds.contains(local)
            blocksInfo.append([
                "range": "\(block.range)",
                "frame": NSStringFromRect(frame),
                "bounds": NSStringFromRect(view.bounds),
                "flipped": view.isFlipped,
                "visible": NSStringFromRect(view.convert(view.visibleRect, to: nil)),
                "local": NSStringFromPoint(local),
                "contains": contains,
                "insertion": contains ? view.characterIndexForInsertion(at: local) : -1,
            ])
        }
        return ["blockCount": blocks.count, "realized": blocksInfo,
                "result": characterIndex(at: point, in: window, anchor: 0) ?? -1]
    }
    #endif

    /// Scrolls the conversation when the pointer is beyond its visible content
    /// (content insets exclude the toolbar and composer overlap). Returns
    /// whether it moved.
    @discardableResult
    static func autoscroll(_ scrollView: NSScrollView, toward point: CGPoint) -> Bool {
        let clip = scrollView.contentView
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        let insets = scrollView.contentInsets
        let top = frame.maxY - insets.top, bottom = frame.minY + insets.bottom
        let distance: CGFloat
        if point.y > top {
            distance = -(point.y - top)
        } else if point.y < bottom {
            distance = bottom - point.y
        } else {
            return false
        }
        // Proportional, bounded steps: a nudge past the edge creeps, a far
        // pointer moves quickly but never jumps whole screens.
        let step = (distance < 0 ? -1 : 1) * min(max(abs(distance), 4), 60)
        var bounds = clip.bounds
        bounds.origin.y += clip.isFlipped ? step : -step
        let origin = clip.constrainBoundsRect(bounds).origin
        guard abs(origin.y - clip.bounds.origin.y) > 0.25 else { return false }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    func container(for id: Int) -> NSTextContainer? { byID[id]?.container }

    /// Stable native members of one coordinated TextKit network. SwiftUI's
    /// lazy rows may retire and realize independently of the loaded messages.
    /// Uncapped Mac rows host these views directly (no per-row scroll wrapper),
    /// so they forward wheel events to the conversation scroll view themselves.
    func textView(for id: Int) -> NSTextView? {
        guard let block = byID[id] else { return nil }
        if let view = block.view { return view }
        let view = MacDirectMessageTextView(frame: .zero, textContainer: block.container)
        block.view = view
        return view
    }

    func range(for id: Int) -> NSRange? { byID[id]?.range }

    func text(for id: Int) -> NSAttributedString? { byID[id]?.text }

    /// Lazy rows may be recreated during reflow. Reuse detached measurements
    /// across those lifetimes, bounded to the recently visible working set.
    func measurement(for id: Int) -> MacTextMeasurement? {
        guard byID[id] != nil else { return nil }
        let measurement = measurements[id] ?? MacTextMeasurement()
        measurements[id] = measurement
        measurementOrder.removeAll { $0 == id }
        measurementOrder.append(id)
        if measurementOrder.count > 32 {
            measurements.removeValue(forKey: measurementOrder.removeFirst())
        }
        return measurement
    }

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

/// Detached from the live selection network so measuring cannot mutate it.
@MainActor
final class MacTextMeasurement {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var source: NSAttributedString?
    private var sizes: [CGFloat: CGSize] = [:]
    private var widths: [CGFloat] = []

    init() {
        storage.addLayoutManager(layout)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
    }

    func size(for text: NSAttributedString, font: NSFont, width: CGFloat) -> CGSize {
        if source !== text {
            storage.setAttributedString(text)
            source = text
            sizes.removeAll()
            widths.removeAll()
        }
        widths.removeAll { $0 == width }
        widths.append(width)
        if let cached = sizes[width] { return cached }
        if container.size.width != width { container.size.width = width }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let result = CGSize(width: min(ceil(max(used.width, 1)), width),
                            height: ceil(max(used.height, layout.defaultLineHeight(for: font))))
        sizes[width] = result
        if widths.count > 64 { sizes.removeValue(forKey: widths.removeFirst()) }
        return result
    }
}
#endif
