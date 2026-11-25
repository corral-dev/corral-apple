#if os(macOS)
import AppKit

/// Optional media behavior; the text network does not own engine/cache policy.
@MainActor protocol MacMessageMediaAttachment {
    var original: String { get }
    var selectionLength: Int { get }
    func open()
}

#if DEBUG
/// Phase-2 first-scroll attribution: where does a newly realized row's
/// layout-phase time go? Main-thread only (AppKit representable path).
/// DEBUG-only accumulators; no behavior change, never read in release.
@MainActor
enum MacFirstScrollAttribution {
    static var makeCalls = 0
    static var makeMs = 0.0
    /// NSTextView acquisition inside makeNSView (document reuse or fresh init).
    static var textViewMs = 0.0
    /// Mount/scroll-wrapper creation + apply inside makeNSView.
    static var mountApplyMs = 0.0
    /// attach (addSubview) alone, split out of mountApplyMs.
    static var attachMs = 0.0
    /// apply alone, split out of mountApplyMs.
    static var applyMs = 0.0
    static var updateCalls = 0
    static var updateMs = 0.0
    static var convertedCalls = 0
    static var convertedMs = 0.0
    static var measureCalls = 0
    static var measureMs = 0.0
    static func reset() {
        makeCalls = 0; makeMs = 0
        textViewMs = 0; mountApplyMs = 0; attachMs = 0; applyMs = 0
        updateCalls = 0; updateMs = 0
        convertedCalls = 0; convertedMs = 0
        measureCalls = 0; measureMs = 0
    }
}

@MainActor
func macAttr<T>(_ accum: inout Double, _ body: () -> T) -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = body()
    accum += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    return result
}
#endif

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

/// SwiftUI's own scroll geometry per conversation document, so the rendering
/// inspection can compare it with the AppKit clip view it observes.
@MainActor
enum MacChatScrollGeometryProbe {
    static var latest: [ObjectIdentifier: [String: Any]] = [:]
}
#endif

/// Single-authority TextKit 1 engine for one standalone message or rich text block.
///
/// One `NSTextStorage` -> `NSLayoutManager` -> `NSTextContainer` (`widthTracksTextView = false`,
/// infinite height) both measures and draws the text. There is no detached second
/// layout engine and no cross-message `.containerBreak` / synthetic paragraph break.
@MainActor
final class MacSingleTextEngine {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private(set) var text = NSAttributedString()
    private var defaultFont = NSFont.systemFont(ofSize: 14)
    private var sizes: [CGFloat: CGSize] = [:]
    private var widths: [CGFloat] = []

    init() {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    func setText(_ next: NSAttributedString, font: NSFont) {
        if text === next && defaultFont == font { return }
        text = next
        defaultFont = font
        storage.setAttributedString(next)
        sizes.removeAll(keepingCapacity: true)
        widths.removeAll(keepingCapacity: true)
    }

    /// Measures and lays out this block directly on its drawing container.
    /// When the text hugs narrower than `proposalWidth` (e.g. short user bubbles),
    /// the container settles at `fittedWidth` so `NSTextTable`/attachments match
    /// the exact width the mounted `NSTextView` receives.
    func size(forProposalWidth width: CGFloat, font: NSFont? = nil) -> CGSize {
        let effectiveFont = font ?? defaultFont
        if let font, font != defaultFont {
            defaultFont = font
            sizes.removeAll(keepingCapacity: true)
            widths.removeAll(keepingCapacity: true)
        }
        widths.removeAll { $0 == width }
        widths.append(width)
        if let cached = sizes[width] {
            if abs(container.size.width - cached.width) > 0.01 || container.size.height != CGFloat.greatestFiniteMagnitude {
                container.size = NSSize(width: cached.width, height: CGFloat.greatestFiniteMagnitude)
                layout.ensureLayout(for: container)
                container.textView?.needsDisplay = true
            }
            return cached
        }

        if abs(container.size.width - width) > 0.01 || container.size.height != CGFloat.greatestFiniteMagnitude {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let fittedWidth = min(ceil(max(measuredContentWidth(), 1)), width)
        if abs(fittedWidth - width) > 0.01 {
            container.size.width = fittedWidth
            layout.ensureLayout(for: container)
        }
        let finalUsed = layout.usedRect(for: container)
        let height = finalUsed.maxY > 0 ? finalUsed.maxY : layout.defaultLineHeight(for: effectiveFont)
        let result = CGSize(
            width: fittedWidth,
            height: ceil(height)
        )
        sizes[width] = result
        if widths.count > 12 {
            sizes.removeValue(forKey: widths.removeFirst())
        }
        return result
    }

    /// True horizontal extent of laid-out lines and `NSTextTableBlock` boxes.
    /// Once a `NSTextView` is attached to `container`, resizing `container.size.width`
    /// makes `NSLayoutManager.usedRect(for:)` report the full container width even for
    /// short text; `enumerateLineFragments` preserves the true content extent.
    private func measuredContentWidth() -> CGFloat {
        let layout = self.layout
        let storage = self.storage
        let glyphs = layout.glyphRange(for: container)
        var maxX: CGFloat = 0
        if glyphs.length > 0 {
            layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, usedRect, _, fragmentGlyphs, _ in
                var lineRight = usedRect.maxX
                let character = layout.characterIndexForGlyph(at: fragmentGlyphs.location)
                if character < storage.length,
                   let paragraph = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle,
                   !paragraph.textBlocks.isEmpty {
                    var blockRight = lineRect.maxX
                    for block in paragraph.textBlocks {
                        blockRight += block.width(for: .padding, edge: .maxX)
                            + block.width(for: .border, edge: .maxX)
                            + block.width(for: .margin, edge: .maxX)
                    }
                    lineRight = max(lineRight, blockRight)
                }
                maxX = max(maxX, lineRight)
            }
        }
        let extraUsed = layout.extraLineFragmentUsedRect
        if !extraUsed.isEmpty {
            maxX = max(maxX, extraUsed.maxX)
        }
        return maxX
    }

    /// Keeps the drawing container aligned with the view's realized bounds.
    func syncContainerWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        if abs(container.size.width - width) > 0.25 || container.size.height != CGFloat.greatestFiniteMagnitude {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

/// Uncapped Mac rows (the default: the conversation scrolls, not the bubble)
/// host their text view directly instead of inside a per-row scroll wrapper.
/// Wheel events forward to the conversation scroll view.
final class MacDirectMessageTextView: NSTextView {
    weak var document: MacConversationTextDocument?
    var messageID: Int?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isText(at: event) else { return paneSessionContextMenu() }
        return super.menu(for: event)
    }

    /// TextKit returns the nearest glyph even in empty line/padding space;
    /// require an actual glyph in this message's own text container.
    func isText(at event: NSEvent) -> Bool {
        guard let layout = layoutManager, let container = textContainer else { return false }
        let location = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: location.x - textContainerOrigin.x, y: location.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: point, in: container)
        guard NSLocationInRange(glyph, layout.glyphRange(for: container)),
              !layout.propertyForGlyph(at: glyph).contains(.controlCharacter) else { return false }
        return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    /// Path mentions open Finder (`MacPathLinks`); other links stay native.
    override func clicked(onLink link: Any, at charIndex: Int) {
        if MacPathLinks.open(link) { return }
        super.clicked(onLink: link, at: charIndex)
    }

    /// A plain press-and-drag selects across the conversation's independent
    /// message blocks. Word/paragraph clicks, modified clicks and links keep
    /// native handling.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, isText(at: event), let storage = textStorage {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if index < storage.length, let diagram = storage.attribute(.attachment, at: index, effectiveRange: nil) as? any MacMessageMediaAttachment {
                diagram.open()
                return
            }
        }
        guard event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let document,
              !isLink(at: event) else {
            super.mouseDown(with: event)
            if let document, !document.isSyncingSelection {
                document.singleViewDidChangeSelection(self)
            }
            return
        }
        document.trackSelection(from: self, mouseDown: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // When another block in the same conversation holds firstResponder during
        // a cross-message selection, paint the active selection highlight color
        // uniformly instead of AppKit's inactive gray on sibling blocks.
        if let document, let window, window.isKeyWindow, window.firstResponder !== self,
           document.isActivelyFocused(in: window), selectedRange().length > 0,
           let layout = layoutManager, let container = textContainer {
            let glyphs = layout.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
            if glyphs.length > 0 {
                let drawRange = layout.glyphRange(forBoundingRect: dirtyRect, in: container)
                layout.drawBackground(forGlyphRange: drawRange, at: textContainerOrigin)
                NSColor.selectedTextBackgroundColor.setFill()
                layout.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    let offsetRect = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                        .intersection(dirtyRect)
                    if !offsetRect.isEmpty { offsetRect.fill() }
                }
                layout.drawGlyphs(forGlyphRange: drawRange, at: textContainerOrigin)
                return
            }
        }
        super.draw(dirtyRect)
    }

    override func copy(_ sender: Any?) {
        if let document, document.copySelection(to: NSPasteboard.general) {
            return
        }
        super.copy(sender)
    }

    override func selectAll(_ sender: Any?) {
        if let document {
            document.selectAll(from: self)
            return
        }
        super.selectAll(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return (document?.hasSelection == true) || selectedRange().length > 0
        }
        if item.action == #selector(selectAll(_:)) {
            return (document?.blockCount ?? 0) > 0 || (textStorage?.length ?? 0) > 0
        }
        return super.validateUserInterfaceItem(item)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        if let document, document.hasMultiBlockSelection {
            return document.copySelection(to: pboard, types: types)
        }
        return super.writeSelection(to: pboard, types: types)
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let document, document.hasMultiBlockSelection {
            return document.copySelection(to: pboard, types: [type])
        }
        if type == .string, let storage = textStorage, NSMaxRange(selectedRange()) <= storage.length {
            let selected = Self.plainStringReplacingAttachments(in: storage, range: selectedRange())
            if let selected {
                return pboard.setString(selected, forType: type)
            }
        }
        return super.writeSelection(to: pboard, type: type)
    }

    static func plainStringReplacingAttachments(in storage: NSAttributedString, range: NSRange) -> String? {
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return nil }
        let selected = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        var sources: [(NSRange, String)] = []
        selected.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            if let media = value as? any MacMessageMediaAttachment { sources.append((range, media.original)) }
        }
        guard !sources.isEmpty else { return nil }
        for (range, source) in sources.reversed() { selected.replaceCharacters(in: range, with: source) }
        return selected.string
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

/// SwiftUI owns one mount per representable lifetime. Each message block owns
/// its reusable text view, which can outlive that mount lifetime.
final class MacMessageTextMount: NSView {
    private(set) var textView: NSTextView?

    override var isFlipped: Bool { true }

    func attach(_ view: NSTextView) {
        guard textView !== view || view.superview !== self else { return }
        if let previous = view.superview as? MacMessageTextMount {
            previous.textView = nil
        }
        releaseTextView()
        view.removeFromSuperview()
        textView = view
        view.autoresizingMask = []
        addSubview(view)
        needsLayout = true
    }

    func releaseTextView() {
        guard let view = textView else { return }
        textView = nil
        guard view.superview === self else { return }
        MacConversationTextDocument.retireTextView(view)
        view.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        guard let view = textView, view.superview === self,
              bounds.width > 0, bounds.height > 0 else { return }
        // Sync the drawing container's width with the realized mount bounds;
        // `widthTracksTextView` is false so speculative zero-sized placements
        // can never collapse the container.
        if let container = view.textContainer,
           abs(container.size.width - bounds.width) > 0.25 || container.size.height != CGFloat.greatestFiniteMagnitude {
            container.size = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
            view.layoutManager?.ensureLayout(for: container)
            view.needsDisplay = true
        }
        if view.frame != bounds { view.frame = bounds }
    }
}

/// Per-conversation coordinator of independent single-message TextKit 1 stacks.
///
/// Each message owns an isolated `MacSingleTextEngine` (`NSTextStorage`,
/// `NSLayoutManager`, `NSTextContainer`) and reusable `MacDirectMessageTextView`.
/// The coordinator manages cross-message drag selection, uniform highlight
/// synchronization across realized and recycled blocks, and unified Copy.
@MainActor
final class MacConversationTextDocument: NSObject, @MainActor NSTextViewDelegate {
    struct Source: Equatable {
        let id: Int
        let text: String
        let isUser: Bool
        var mediaRevision: Int = 0
        var isStreaming: Bool = false
    }

    struct Style: Equatable {
        let font: NSFont
        let foreground: NSColor
        let userForeground: NSColor
    }

    private final class Block {
        let engine = MacSingleTextEngine()
        var source: Source
        var view: MacDirectMessageTextView?

        init(source: Source, text: NSAttributedString, font: NSFont) {
            self.source = source
            engine.setText(text, font: font)
        }
    }

    struct Position: Equatable {
        let id: Int
        let offset: Int
    }

    struct Selection: Equatable {
        var anchor: Position
        var head: Position
    }

    private var identity: ObjectIdentifier?
    private var sources: [Source] = []
    private var style: Style?
    private var blocks: [Block] = []
    private var byID: [Int: Block] = [:]
    private var indexByID: [Int: Int] = [:]
    private var selection: Selection?
    private(set) var isSyncingSelection = false

    var blockCount: Int { blocks.count }

    /// The conversation table's measured row heights (owned and typed by the
    /// table), kept with the document so a rebuilt table reuses them.
    var tableRowHeights: AnyObject?

    /// Only changed messages are rendered. Blocks for unloaded SwiftUI rows
    /// stay owned here, so lazy realization keeps exact single-source geometry
    /// and cross-message selection.
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
            selection = nil
        }
        let oldByID = sameConversation ? byID : [:]
        let styleChanged = self.style != style

        isSyncingSelection = true
        let next = sources.map { source -> Block in
            if let existing = oldByID[source.id] {
                if existing.source != source || styleChanged {
                    existing.source = source
                    existing.engine.setText(render(source), font: style.font)
                    existing.view?.needsDisplay = true
                }
                return existing
            }
            return Block(source: source, text: render(source), font: style.font)
        }
        isSyncingSelection = false

        blocks = next
        byID = Dictionary(uniqueKeysWithValues: next.map { ($0.source.id, $0) })
        indexByID = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($1.source.id, $0) })
        self.identity = identity
        self.sources = sources
        self.style = style

        if let sel = selection, byID[sel.anchor.id] == nil || byID[sel.head.id] == nil {
            selection = nil
        }
        syncSelectionToViews(stillSelecting: false)
    }

    /// Single-authority measurement directly on the block's own drawing container.
    func size(for id: Int, proposalWidth: CGFloat, font: NSFont? = nil) -> CGSize? {
        byID[id]?.engine.size(forProposalWidth: proposalWidth, font: font ?? style?.font)
    }

    func container(for id: Int) -> NSTextContainer? { byID[id]?.engine.container }

    func storage(for id: Int) -> NSTextStorage? { byID[id]?.engine.storage }

    func layout(for id: Int) -> NSLayoutManager? { byID[id]?.engine.layout }

    func text(for id: Int) -> NSAttributedString? { byID[id]?.engine.text }

    func range(for id: Int) -> NSRange? {
        guard let block = byID[id] else { return nil }
        return NSRange(location: 0, length: block.engine.storage.length)
    }

    /// Combined text across all blocks in reading order (for inspection/tests).
    func combinedAttributedText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(block.engine.storage)
        }
        return result
    }

    /// Stable native text view for a loaded message block.
    func textView(for id: Int) -> NSTextView? {
        guard let block = byID[id] else { return nil }
        if let view = block.view { return view }
        let view = MacDirectMessageTextView(frame: .zero, textContainer: block.engine.container)
        view.document = self
        view.messageID = id
        view.delegate = self
        block.view = view
        let range = selectedRange(for: id)
        if range.length > 0 {
            isSyncingSelection = true
            view.setSelectedRange(range)
            isSyncingSelection = false
        }
        return view
    }

    /// Releases offscreen native text views no longer mounted in any row mount,
    /// keeping their TextKit engines, active selection and mounted views intact.
    func releaseDetachedViews() {
        for block in blocks {
            guard let view = block.view, view.superview == nil else { continue }
            Self.retireTextView(view)
            block.view = nil
            if block.engine.container.textView === view {
                block.engine.container.textView = nil
            }
            view.delegate = nil
            view.document = nil
        }
    }

    var hasSelection: Bool {
        guard let ordered = orderedSelection() else { return false }
        return ordered.startIndex != ordered.endIndex || ordered.startOffset != ordered.endOffset
    }

    var hasMultiBlockSelection: Bool {
        guard let ordered = orderedSelection() else { return false }
        return ordered.startIndex != ordered.endIndex
    }

    func isActivelyFocused(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? MacDirectMessageTextView else { return false }
        return responder.document === self
    }

    func selectedRange(for id: Int) -> NSRange {
        guard let block = byID[id], let blockIndex = indexByID[id],
              let ordered = orderedSelection() else {
            return NSRange(location: 0, length: 0)
        }
        let length = block.engine.storage.length
        if blockIndex < ordered.startIndex || blockIndex > ordered.endIndex {
            return NSRange(location: 0, length: 0)
        }
        if ordered.startIndex == ordered.endIndex {
            let start = min(max(0, ordered.startOffset), length)
            let end = min(max(start, ordered.endOffset), length)
            return NSRange(location: start, length: end - start)
        }
        if blockIndex == ordered.startIndex {
            let start = min(max(0, ordered.startOffset), length)
            return NSRange(location: start, length: length - start)
        }
        if blockIndex == ordered.endIndex {
            let end = min(max(0, ordered.endOffset), length)
            return NSRange(location: 0, length: end)
        }
        return NSRange(location: 0, length: length)
    }

    func selectedPlainText() -> String {
        guard let ordered = orderedSelection(),
              ordered.startIndex <= ordered.endIndex else { return "" }
        var parts: [String] = []
        for idx in ordered.startIndex...ordered.endIndex where blocks.indices.contains(idx) {
            let block = blocks[idx]
            let range = selectedRange(for: block.source.id)
            guard range.length > 0 else { continue }
            let storage = block.engine.storage
            let plain = MacDirectMessageTextView.plainStringReplacingAttachments(in: storage, range: range)
                ?? (storage.string as NSString).substring(with: range)
            parts.append(plain)
        }
        return parts.joined(separator: "\n\n")
    }

    func selectedAttributedText() -> NSAttributedString {
        guard let ordered = orderedSelection(),
              ordered.startIndex <= ordered.endIndex else { return NSAttributedString() }
        let combined = NSMutableAttributedString()
        var wroteAny = false
        for idx in ordered.startIndex...ordered.endIndex where blocks.indices.contains(idx) {
            let block = blocks[idx]
            let range = selectedRange(for: block.source.id)
            guard range.length > 0 else { continue }
            if wroteAny {
                combined.append(NSAttributedString(string: "\n\n", attributes: style.map { [.font: $0.font] } ?? [:]))
            }
            combined.append(block.engine.storage.attributedSubstring(from: range))
            wroteAny = true
        }
        return combined
    }

    @discardableResult
    func copySelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]? = nil) -> Bool {
        guard hasSelection else { return false }
        let plain = selectedPlainText()
        let rich = selectedAttributedText()
        let allowed = types ?? [.rtf, .rtfd, .string]
        var declared: [NSPasteboard.PasteboardType] = []
        if allowed.contains(.rtfd) && rich.containsAttachments(in: NSRange(location: 0, length: rich.length)) {
            declared.append(.rtfd)
        }
        if allowed.contains(.rtf) {
            declared.append(.rtf)
        }
        if allowed.contains(.string) {
            declared.append(.string)
        }
        if declared.isEmpty { declared = [.string] }
        pboard.declareTypes(declared, owner: nil)
        var wrote = false
        if declared.contains(.rtfd),
           let data = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            wrote = pboard.setData(data, forType: .rtfd) || wrote
        }
        if declared.contains(.rtf),
           let data = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            wrote = pboard.setData(data, forType: .rtf) || wrote
        }
        if declared.contains(.string) {
            wrote = pboard.setString(plain, forType: .string) || wrote
        }
        return wrote
    }

    func selectAll(from origin: MacDirectMessageTextView) {
        guard let first = blocks.first, let last = blocks.last else { return }
        origin.window?.makeFirstResponder(origin)
        selection = Selection(
            anchor: position(in: first, localOffset: 0),
            head: position(in: last, localOffset: last.engine.storage.length)
        )
        syncSelectionToViews(stillSelecting: false)
    }

    #if DEBUG
    func setSelectionForInspection(from start: (id: Int, offset: Int), to end: (id: Int, offset: Int),
                                   responder: MacDirectMessageTextView) {
        guard let startBlock = byID[start.id], let endBlock = byID[end.id] else { return }
        responder.window?.makeFirstResponder(responder)
        selection = Selection(
            anchor: position(in: startBlock, localOffset: start.offset),
            head: position(in: endBlock, localOffset: end.offset)
        )
        syncSelectionToViews(stillSelecting: false)
    }
    #endif

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isSyncingSelection, let view = notification.object as? MacDirectMessageTextView else { return }
        singleViewDidChangeSelection(view)
    }

    func singleViewDidChangeSelection(_ view: MacDirectMessageTextView) {
        guard !isSyncingSelection,
              let id = view.messageID,
              let block = byID[id] else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            if selection != nil {
                selection = nil
                syncSelectionToViews(stillSelecting: false, skipping: view)
            }
            return
        }
        selection = Selection(
            anchor: position(in: block, localOffset: range.location),
            head: position(in: block, localOffset: NSMaxRange(range))
        )
        syncSelectionToViews(stillSelecting: false, skipping: view)
    }

    /// Tracks a press-and-drag that began on `origin` until the button is
    /// released. Every step resolves the pointer against the on-screen geometry
    /// of this conversation's independent blocks; scrolled-offscreen blocks
    /// between anchor and head keep their selection in `selection` and apply it
    /// if scrolled back into view.
    func trackSelection(from origin: MacDirectMessageTextView, mouseDown event: NSEvent) {
        guard let window = origin.window,
              let originID = origin.messageID,
              let originBlock = byID[originID] else { return }
        let scrollView = origin.enclosingScrollView
        let anchorLocal = min(max(0, origin.characterIndexForInsertion(at: origin.convert(event.locationInWindow, from: nil))),
                              originBlock.engine.storage.length)
        let anchorPos = position(in: originBlock, localOffset: anchorLocal)
        var currentPos = anchorPos
        window.makeFirstResponder(origin)
        #if DEBUG
        Self.selectionTrace = [("anchor", anchorLocal)]
        if let clip = scrollView?.contentView {
            Self.selectionTrace.append(("offDown", Int(clip.bounds.origin.y)))
            Self.selectionTrace.append(("frDown", Int(origin.convert(origin.bounds, to: nil).minY)))
        }
        #endif
        func applyDrag(_ pos: Position, stillSelecting: Bool) {
            currentPos = pos
            if stillSelecting || pos != anchorPos {
                selection = Selection(anchor: anchorPos, head: pos)
            } else {
                selection = nil
            }
            syncSelectionToViews(stillSelecting: stillSelecting, caretFallback: stillSelecting ? nil : (origin, anchorLocal))
        }
        applyDrag(anchorPos, stillSelecting: true)
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var pointer = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            switch next.type {
            case .leftMouseDragged:
                pointer = next.locationInWindow
            case .periodic:
                guard let scrollView, Self.autoscroll(scrollView, toward: pointer) else { continue }
                #if DEBUG
                Self.selectionTrace.append(("scroll", Int(scrollView.contentView.bounds.origin.y)))
                #endif
            default:
                pointer = next.locationInWindow
                let routed = position(at: pointer, in: window, anchor: anchorPos)
                #if DEBUG
                Self.selectionTrace.append(("up", routed.map { localOffset(for: $0) } ?? -1))
                if let clip = scrollView?.contentView {
                    Self.selectionTrace.append(("offUp", Int(clip.bounds.origin.y)))
                    Self.selectionTrace.append(("frUp", Int(origin.convert(origin.bounds, to: nil).minY)))
                }
                #endif
                applyDrag(routed ?? currentPos, stillSelecting: false)
                return
            }
            if next.type == .leftMouseDragged, let scrollView {
                if Self.autoscroll(scrollView, toward: pointer) {
                    #if DEBUG
                    Self.selectionTrace.append(("scroll", Int(scrollView.contentView.bounds.origin.y)))
                    #endif
                }
            }
            let routed = position(at: pointer, in: window, anchor: anchorPos)
            #if DEBUG
            Self.selectionTrace.append(("drag", routed.map { localOffset(for: $0) } ?? -1))
            #endif
            applyDrag(routed ?? currentPos, stillSelecting: true)
        }
    }

    #if DEBUG
    /// Per-step routing trace of the in-progress drag inspection.
    static var selectionTrace: [(String, Int)] = []
    #endif

    /// Resolves a window point to a message block and character offset inside it.
    func position(at point: CGPoint, in window: NSWindow, anchor: Position) -> Position? {
        let realized = blocks.compactMap { block -> (Block, MacDirectMessageTextView, CGRect)? in
            guard let view = block.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return (block, view, view.convert(view.bounds, to: nil))
        }.sorted { $0.2.maxY > $1.2.maxY }
        guard let last = realized.last else { return nil }
        for (index, (block, view, frame)) in realized.enumerated() {
            if point.y > frame.maxY {
                guard index > 0 else { return position(in: block, localOffset: 0) }
                let (previous, _, prevFrame) = realized[index - 1]
                // Split the inter-block gap at its midpoint so dragging toward a neighboring
                // block snaps cleanly to that neighbor's nearest boundary (end of above / start of below).
                let midY = (prevFrame.minY + frame.maxY) / 2
                if point.y >= midY {
                    return position(in: previous, localOffset: previous.engine.storage.length)
                }
                return position(in: block, localOffset: 0)
            }
            if point.y >= frame.minY {
                var local = view.convert(point, from: nil)
                local.x = min(max(local.x, 0), view.bounds.width)
                local.y = min(max(local.y, 0), max(view.bounds.height - 1, 0))
                let character = min(max(0, view.characterIndexForInsertion(at: local)), block.engine.storage.length)
                return position(in: block, localOffset: character)
            }
        }
        return position(in: last.0, localOffset: last.0.engine.storage.length)
    }

    #if DEBUG
    var debugIdentity: ObjectIdentifier? { identity }

    /// The storage range of the block currently hosting a realized view.
    func range(of view: NSTextView) -> NSRange? {
        guard let block = blocks.first(where: { $0.view === view }) else { return nil }
        return NSRange(location: 0, length: block.engine.storage.length)
    }

    /// One-shot drag-routing diagnostics for the selection inspection.
    func debugRoute(at point: CGPoint, in window: NSWindow) -> [String: Any] {
        var blocksInfo: [[String: Any]] = []
        let realized = blocks.compactMap { block -> (Block, MacDirectMessageTextView, CGRect)? in
            guard let view = block.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return (block, view, view.convert(view.bounds, to: nil))
        }
        for (block, view, frame) in realized {
            let local = view.convert(point, from: nil)
            let contains = view.bounds.contains(local)
            blocksInfo.append([
                "id": block.source.id,
                "length": block.engine.storage.length,
                "frame": NSStringFromRect(frame),
                "bounds": NSStringFromRect(view.bounds),
                "flipped": view.isFlipped,
                "visible": NSStringFromRect(view.convert(view.visibleRect, to: nil)),
                "local": NSStringFromPoint(local),
                "contains": contains,
                "insertion": contains ? view.characterIndexForInsertion(at: local) : -1,
            ])
        }
        let anchor = blocks.first.map { position(in: $0, localOffset: 0) }
        let resolved = anchor.flatMap { position(at: point, in: window, anchor: $0) }
        return ["blockCount": blocks.count, "realized": blocksInfo,
                "resultID": resolved?.id ?? -1,
                "resultOffset": resolved.map { localOffset(for: $0) } ?? -1]
    }
    #endif

    /// Scrolls the conversation when the pointer is beyond its visible content
    /// (content insets exclude the toolbar and composer overlap).
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
        let step = (distance < 0 ? -1 : 1) * min(max(abs(distance), 4), 60)
        var bounds = clip.bounds
        bounds.origin.y += clip.isFlipped ? step : -step
        let origin = clip.constrainBoundsRect(bounds).origin
        guard abs(origin.y - clip.bounds.origin.y) > 0.25 else { return false }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    /// Transfer focus before a lazy row leaves the native hierarchy.
    static func retireTextView(_ view: NSTextView) {
        if let window = view.window ?? NSApp.windows.first(where: { $0.firstResponder === view }),
           window.firstResponder === view {
            let sibling: NSTextView? = if let direct = view as? MacDirectMessageTextView,
                                         let doc = direct.document {
                doc.blocks.lazy.compactMap { $0.view ?? $0.engine.container.textView }.first {
                    $0 !== view && $0.window === window && !$0.visibleRect.isEmpty
                }
            } else {
                nil
            }
            window.makeFirstResponder(sibling)
        }
    }

    // MARK: - Selection helpers

    private func syncSelectionToViews(
        stillSelecting: Bool,
        skipping skipped: NSTextView? = nil,
        caretFallback: (MacDirectMessageTextView, Int)? = nil
    ) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        let ordered = orderedSelection()
        for block in blocks {
            guard let view = block.view else { continue }
            if view === skipped { continue }
            let range: NSRange
            let affinity: NSSelectionAffinity
            if let ordered {
                range = selectedRange(for: block.source.id)
                affinity = ordered.isReversed ? .upstream : .downstream
            } else if let caretFallback, caretFallback.0 === view {
                let offset = min(max(0, caretFallback.1), block.engine.storage.length)
                range = NSRange(location: offset, length: 0)
                affinity = .downstream
            } else {
                range = NSRange(location: 0, length: 0)
                affinity = .downstream
            }
            if view.selectedRange() != range {
                view.setSelectedRange(range, affinity: affinity, stillSelecting: stillSelecting)
            }
            view.needsDisplay = true
        }
    }

    private struct OrderedSelection {
        let startIndex: Int
        let startOffset: Int
        let endIndex: Int
        let endOffset: Int
        let isReversed: Bool
    }

    private func orderedSelection() -> OrderedSelection? {
        guard let selection,
              let aIdx = indexByID[selection.anchor.id],
              let hIdx = indexByID[selection.head.id] else { return nil }
        let aOff = localOffset(for: selection.anchor)
        let hOff = localOffset(for: selection.head)
        if aIdx < hIdx || (aIdx == hIdx && aOff <= hOff) {
            return OrderedSelection(startIndex: aIdx, startOffset: aOff, endIndex: hIdx, endOffset: hOff, isReversed: false)
        }
        return OrderedSelection(startIndex: hIdx, startOffset: hOff, endIndex: aIdx, endOffset: aOff, isReversed: true)
    }

    private func position(in block: Block, localOffset offset: Int) -> Position {
        let clamped = min(max(0, offset), block.engine.storage.length)
        var sourceOffset = clamped
        block.engine.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: clamped)) { value, range, _ in
            if let media = value as? any MacMessageMediaAttachment {
                sourceOffset += media.selectionLength - range.length
            }
        }
        return Position(id: block.source.id, offset: sourceOffset)
    }

    private func localOffset(for position: Position) -> Int {
        guard let block = byID[position.id] else { return 0 }
        var nativeOffset = position.offset
        var sourceCursor = 0
        var nativeCursor = 0
        let length = block.engine.storage.length
        block.engine.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, stop in
            guard let media = value as? any MacMessageMediaAttachment else { return }
            sourceCursor += range.location - nativeCursor
            let span = media.selectionLength
            if position.offset <= sourceCursor { stop.pointee = true; return }
            if position.offset < sourceCursor + span {
                nativeOffset = range.location
                stop.pointee = true
                return
            }
            nativeOffset -= span - range.length
            sourceCursor += span
            nativeCursor = NSMaxRange(range)
        }
        return min(max(0, nativeOffset), length)
    }
}
#endif
