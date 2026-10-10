#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore

/// 超长气泡内滚时的上下边缘淡出：提示“里面还能滑”。只有被 50% 屏高封顶、
/// 真正进入内滚的气泡才挂 mask，短气泡不受影响。
private final class EdgeFadeTextView: UITextView {
    private static let fadeLength: CGFloat = 28
    private var fadeMask: CAGradientLayer?
    /// Tells SwiftUI whether hidden text remains below, for the scroll-more arrow.
    var onMoreBelowChange: ((Bool) -> Void)?
    private var reportedMoreBelow: Bool?

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshEdgeFade()
    }

    func refreshEdgeFade() {
        let visibleH = bounds.height
        let contentH = contentSize.height
        let canScroll = isScrollEnabled && visibleH > 1 && contentH > visibleH + 1
        let topActive = canScroll && contentOffset.y > 1
        let bottomActive = canScroll && contentOffset.y + visibleH < contentH - 1
        reportMoreBelow(bottomActive)
        guard topActive || bottomActive else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let topStop = topActive ? min(Self.fadeLength / visibleH, 0.4) : 0
        let bottomStop = bottomActive ? min(Self.fadeLength / visibleH, 0.4) : 0
        let mask: CAGradientLayer
        if let existing = fadeMask {
            mask = existing
        } else {
            mask = CAGradientLayer()
            mask.startPoint = CGPoint(x: 0.5, y: 0)
            mask.endPoint = CGPoint(x: 0.5, y: 1)
            fadeMask = mask
            layer.mask = mask
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.colors = [
            UIColor.black.withAlphaComponent(topActive ? 0 : 1).cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.black.withAlphaComponent(bottomActive ? 0 : 1).cgColor,
        ]
        mask.locations = [0, topStop, 1 - bottomStop, 1] as [NSNumber]
        CATransaction.commit()
    }

    /// Runs inside layout/scroll callbacks; SwiftUI state changes hop to the next turn.
    private func reportMoreBelow(_ value: Bool) {
        guard let onMoreBelowChange, reportedMoreBelow != value else { return }
        reportedMoreBelow = value
        DispatchQueue.main.async { onMoreBelowChange(value) }
    }
}

/// Chat / tool body text that supports iOS range selection (loupe + drag handles).
///
/// SwiftUI `Text` + `.textSelection(.enabled)` is not enough: on iOS it often only
/// offers a whole-string menu, not sliding partial selection. A non-editable
/// `UITextView` is the system path Messages-style selection uses.
///
/// Height must come from `sizeThatFits` — an invisible `Text` + overlay collapses to
/// one line inside `ScrollView` / `LazyVStack` (UITextView intrinsic size ignores
/// the proposed width until SwiftUI asks explicitly).
///
/// Optional `maxHeight` caps overlong bubbles (50% screen) and enables inner
/// scrolling. Short text still hugs — never wrap this view in a GeometryReader
/// just to learn the parent size; that expands short user bubbles across the row.
struct SelectableAttributedText: View {
    let attributed: AttributedString
    var foreground: Color = .primary
    var tint: Color = Palette.accent
    var fontStyle: SessionFontStyle = .bubbleBody
    var maxHeight: CGFloat? = nil
    /// Reports whether capped text still has hidden content below the visible part.
    var onMoreBelowChange: ((Bool) -> Void)? = nil

    @Environment(\.sessionTextScale) private var sessionTextScale
    @Environment(\.interfaceScale) private var interfaceScale

    var body: some View {
        SelectableTextView(
            attributed: attributed,
            font: Typography.sessionUIFont(fontStyle, scale: sessionTextScale * interfaceScale),
            foreground: UIColor(foreground),
            tint: UIColor(tint),
            maxHeight: maxHeight,
            onMoreBelowChange: onMoreBelowChange
        )
        .accessibilityLabel(Text(String(attributed.characters)))
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let attributed: AttributedString
    let font: UIFont
    let foreground: UIColor
    let tint: UIColor
    let maxHeight: CGFloat?
    let onMoreBelowChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = EdgeFadeTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.isUserInteractionEnabled = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.adjustsFontForContentSizeCategory = true
        // Let the parent width win so long lines wrap instead of stretching.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        apply(to: uiView, coordinator: context.coordinator)
    }

    /// Drive multi-line height from the proposed width (required inside ScrollView).
    /// Also hug short content so user bubbles stay Messages-tight; assistant bubbles
    /// still fill via `MessageBubbleView`'s `frame(maxWidth: .infinity)`.
    /// When natural height exceeds `maxHeight`, report the cap and scroll inside.
    ///
    /// Must stay side-effect free: SwiftUI calls this during the layout pass, and
    /// mutating the live UITextView here (attributedText, isScrollEnabled, hugging
    /// priorities, layer mask) re-enters layout and corrupts the AttributeGraph
    /// (2026-10-01真机 EXC_BAD_ACCESS in AG::data::zone::realloc_bytes during
    /// ScrollViewDisplayList commit). Measure with a detached sizer and defer the
    /// scroll-mode switch to the next runloop.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let maxWidth = proposal.width ?? (uiView.bounds.width > 1 ? uiView.bounds.width : nil)
        guard let maxWidth, maxWidth.isFinite, maxWidth > 0 else { return nil }

        let coordinator = context.coordinator
        let ns = converted(coordinator)
        let natural: CGSize
        if let cached = coordinator.sizes[maxWidth] {
            natural = cached
        } else {
            natural = Self.naturalSize(for: ns, font: font, proposalWidth: maxWidth)
            if coordinator.sizes.count >= 24 { coordinator.sizes.removeAll() }
            coordinator.sizes[maxWidth] = natural
        }
        let shouldScroll: Bool
        let result: CGSize
        if let maxHeight, natural.height > maxHeight + 0.5 {
            shouldScroll = true
            result = CGSize(width: natural.width, height: maxHeight)
        } else {
            shouldScroll = false
            result = natural
        }
        // SwiftUI measures each bubble several times per pass; only a changed mode
        // needs the deferred update.
        guard coordinator.scheduledScrollMode != shouldScroll else { return result }
        coordinator.scheduledScrollMode = shouldScroll
        let view = uiView
        DispatchQueue.main.async {
            Self.applyScrollMode(to: view, scrolling: shouldScroll)
        }
        return result
    }

    private func apply(to view: UITextView, coordinator: Coordinator) {
        let ns = converted(coordinator)
        let fingerprint = Fingerprint(
            string: ns.string,
            fontSize: font.pointSize,
            foreground: foreground,
            tint: tint,
            maxHeight: maxHeight
        )
        if coordinator.fingerprint != fingerprint {
            let previous = view.selectedRange
            view.attributedText = ns
            if previous.length > 0, NSMaxRange(previous) <= ns.length {
                view.selectedRange = previous
            }
            coordinator.fingerprint = fingerprint
        }
        view.linkTextAttributes = [
            .foregroundColor: tint,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.tintColor = tint
        (view as? EdgeFadeTextView)?.onMoreBelowChange = onMoreBelowChange
        (view as? EdgeFadeTextView)?.refreshEdgeFade()
    }

    private static func applyScrollMode(to view: UITextView, scrolling: Bool) {
        if view.isScrollEnabled != scrolling {
            view.isScrollEnabled = scrolling
        }
        view.showsVerticalScrollIndicator = scrolling
        if scrolling {
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        } else {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        (view as? EdgeFadeTextView)?.refreshEdgeFade()
    }

    /// Stateless measurement: a detached sizer mirrors makeUIView's text-container
    /// config but never joins the hierarchy, so the result can't depend on (or
    /// disturb) the live view's scroll state. Measuring the live view here used
    /// to toggle isScrollEnabled mid-layout and oscillate around the cap.
    private static func naturalSize(
        for ns: NSAttributedString,
        font: UIFont,
        proposalWidth: CGFloat
    ) -> CGSize {
        let constraint = CGSize(width: proposalWidth, height: .greatestFiniteMagnitude)
        let used = ns.boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let sizer = UITextView()
        sizer.backgroundColor = .clear
        sizer.isEditable = false
        sizer.isSelectable = false
        sizer.isScrollEnabled = false
        sizer.textContainerInset = .zero
        sizer.textContainer.lineFragmentPadding = 0
        sizer.textContainer.widthTracksTextView = true
        sizer.attributedText = ns
        let fitted = sizer.sizeThatFits(constraint)
        let height = ceil(max(fitted.height, used.height, font.lineHeight))
        let hugged = ceil(max(used.width, 1))
        return CGSize(width: min(hugged, proposalWidth), height: height)
    }

    /// Conversion and measurement repeat for every layout pass and scroll-in of a
    /// bubble; cache both until the text or its styling changes (as on the Mac).
    private func converted(_ coordinator: Coordinator) -> NSAttributedString {
        let source = Source(attributed: attributed, fontSize: font.pointSize, foreground: foreground)
        if coordinator.source == source, let converted = coordinator.converted {
            return converted
        }
        let ns = nsAttributedString()
        coordinator.source = source
        coordinator.converted = ns
        coordinator.sizes.removeAll()
        return ns
    }

    private func nsAttributedString() -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: mutable.length)
        guard full.length > 0 else { return mutable }

        let reference = ChatMarkdown.referenceBodyPointSize
        mutable.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var next = attrs
            if let existing = attrs[.font] as? UIFont {
                // ChatMarkdown bakes fonts at a fixed reference size; rescale to the
                // session text size while keeping weight / monospaced / italic.
                let ratio = existing.pointSize / max(reference, 1)
                next[.font] = Self.resized(existing, to: font.pointSize * ratio)
            } else if let inline = attrs[.inlinePresentationIntent] as? InlinePresentationIntent {
                next[.font] = Self.font(for: inline, base: font)
            } else {
                next[.font] = font
            }
            if attrs[.foregroundColor] == nil {
                next[.foregroundColor] = foreground
            }
            mutable.setAttributes(next, range: range)
        }
        return mutable
    }

    private static func resized(_ font: UIFont, to size: CGFloat) -> UIFont {
        let descriptor = font.fontDescriptor
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func font(for intent: InlinePresentationIntent, base: UIFont) -> UIFont {
        if intent.contains(.code) {
            return UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if intent.contains(.stronglyEmphasized) {
            return UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        }
        if intent.contains(.emphasized) {
            traits.insert(.traitItalic)
            if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: descriptor, size: base.pointSize)
            }
        }
        return base
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var fingerprint: Fingerprint?
        var source: Source?
        var converted: NSAttributedString?
        var sizes: [CGFloat: CGSize] = [:]
        /// Last scroll mode queued for the live view; nil until the first measurement.
        var scheduledScrollMode: Bool?

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? EdgeFadeTextView)?.refreshEdgeFade()
        }
    }

    struct Fingerprint: Equatable {
        let string: String
        let fontSize: CGFloat
        let foreground: UIColor
        let tint: UIColor
        let maxHeight: CGFloat?
    }

    struct Source: Equatable {
        let attributed: AttributedString
        let fontSize: CGFloat
        let foreground: UIColor
    }
}
#elseif os(macOS)
import SwiftUI
import AppKit
import QuartzCore

/// Mac counterpart of the iOS selectable bubble text: a non-editable
/// `NSTextView` gives native partial selection, Copy, link handling and the
/// context menu. Overlong text scrolls inside the bubble behind the same
/// height cap, with edge fades and the scroll-more report used on iOS.
struct SelectableAttributedText: View {
    let attributed: AttributedString
    var foreground: Color = .primary
    var tint: Color = Palette.accent
    var fontStyle: SessionFontStyle = .bubbleBody
    var maxHeight: CGFloat? = nil
    var onMoreBelowChange: ((Bool) -> Void)? = nil

    @Environment(\.sessionTextScale) private var sessionTextScale
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.macConversationTextDocument) private var document
    @Environment(\.macMessageSelectionID) private var selectionID

    var body: some View {
        MacSelectableTextView(
            attributed: attributed,
            font: Typography.sessionUIFont(fontStyle, scale: sessionTextScale * interfaceScale),
            foreground: NSColor(foreground),
            tint: NSColor(tint),
            maxHeight: maxHeight,
            onMoreBelowChange: onMoreBelowChange,
            document: document,
            selectionID: selectionID
        )
        .accessibilityLabel(Text(String(attributed.characters)))
    }
}

/// Scroll container that fades the clipped edges and reports hidden text below.
private final class FadingTextScrollView: NSScrollView {
    private static let fadeLength: CGFloat = 24
    var onMoreBelowChange: ((Bool) -> Void)?
    private var reportedMoreBelow: Bool?
    private var fadeMask: CAGradientLayer?

    override func layout() {
        super.layout()
        refreshEdgeFade()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        refreshEdgeFade()
    }

    /// A non-scrolling bubble passes wheel events to the conversation.
    override func scrollWheel(with event: NSEvent) {
        if hasVerticalScroller {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    func refreshEdgeFade() {
        wantsLayer = true
        let visible = contentView.bounds
        let contentHeight = documentView?.frame.height ?? 0
        let canScroll = hasVerticalScroller && visible.height > 1 && contentHeight > visible.height + 1
        let topActive = canScroll && visible.minY > 1
        let bottomActive = canScroll && visible.maxY < contentHeight - 1
        reportMoreBelow(bottomActive)
        guard let layer else { return }
        guard topActive || bottomActive else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let height = max(bounds.height, 1)
        let topStop = topActive ? min(Self.fadeLength / height, 0.4) : 0
        let bottomStop = bottomActive ? min(Self.fadeLength / height, 0.4) : 0
        let mask = fadeMask ?? CAGradientLayer()
        if fadeMask == nil {
            fadeMask = mask
        }
        layer.mask = mask
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = layer.bounds
        // The scroll view's backing layer is geometry-flipped: location 0 is the top edge
        // (verified on screen 2026-10-04; the unflipped assumption faded the wrong edge).
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.colors = [
            NSColor.black.withAlphaComponent(topActive ? 0 : 1).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(bottomActive ? 0 : 1).cgColor,
        ]
        mask.locations = [0, topStop, 1 - bottomStop, 1] as [NSNumber]
        CATransaction.commit()
    }

    private func reportMoreBelow(_ value: Bool) {
        guard let onMoreBelowChange, reportedMoreBelow != value else { return }
        reportedMoreBelow = value
        DispatchQueue.main.async { onMoreBelowChange(value) }
    }
}

private struct MacSelectableTextView: NSViewRepresentable {
    let attributed: AttributedString
    let font: NSFont
    let foreground: NSColor
    let tint: NSColor
    let maxHeight: CGFloat?
    let onMoreBelowChange: ((Bool) -> Void)?
    var document: MacConversationTextDocument?
    var selectionID: Int?

    /// Conversion to NSAttributedString and measurement are the cost of a
    /// window resize (SwiftUI measures each visible bubble several times per
    /// width), so both are cached until the text or its styling changes.
    final class Coordinator {
        var fingerprint: Fingerprint?
        var source: Source?
        var converted: NSAttributedString?
        var sizes: [CGFloat: CGSize] = [:]
        /// Keep the chosen native text network alive through representable updates.
        var textStorage: NSTextStorage?
    }

    struct Source: Equatable {
        let attributed: AttributedString
        let fontSize: CGFloat
        let foreground: NSColor
    }

    struct Fingerprint: Equatable {
        let string: String
        let fontSize: CGFloat
        let foreground: NSColor
        let tint: NSColor
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FadingTextScrollView {
        let scroll = FadingTextScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none

        let container = selectionID.flatMap { document?.container(for: $0) }
        let storage = container == nil ? NSTextStorage() : (document?.storage ?? NSTextStorage())
        context.coordinator.textStorage = storage
        let textView: NSTextView
        if let selectionID, let existing = document?.textView(for: selectionID) {
            textView = existing
            // A replacement row can realize before the outgoing row dismantles.
            // AppKit keeps the view's original text network and selection.
            textView.removeFromSuperview()
        } else {
            textView = Self.makeTextView(storage: storage)
        }
        // These flags are shared across the conversation's native text network.
        // Reassigning selectability while reattaching a lazy row can lay out all
        // preceding containers even when the value is already correct.
        if textView.isEditable { textView.isEditable = false }
        if !textView.isSelectable { textView.isSelectable = true }
        textView.drawsBackground = false
        if !textView.isRichText { textView.isRichText = true }
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: container == nil ? .greatestFiniteMagnitude : MacConversationTextDocument.initialCanvasHeight
        )
        textView.autoresizingMask = [.width]
        textView.focusRingType = .none
        scroll.documentView = textView
        apply(to: scroll, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: FadingTextScrollView, context: Context) {
        apply(to: scroll, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ scroll: FadingTextScrollView, coordinator: Coordinator) {
        scroll.onMoreBelowChange = nil
        if let view = scroll.documentView as? NSTextView, view.enclosingScrollView === scroll {
            MacConversationTextDocument.retireTextView(view)
        }
        coordinator.textStorage = nil
    }

    /// Side-effect free measurement with a detached layout; the scroll mode switch
    /// is deferred so layout never re-enters (same rule as the iOS host).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FadingTextScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let coordinator = context.coordinator
        let ns = converted(coordinator)
        let natural: CGSize
        if let cached = coordinator.sizes[width] {
            natural = cached
        } else {
            natural = Self.naturalSize(for: ns, font: font, width: width)
            if coordinator.sizes.count >= 24 { coordinator.sizes.removeAll() }
            coordinator.sizes[width] = natural
        }
        let scrolling = maxHeight.map { natural.height > $0 + 0.5 } ?? false
        let result = scrolling ? CGSize(width: natural.width, height: maxHeight ?? natural.height) : natural
        if let container = selectionID.flatMap({ document?.container(for: $0) }),
           container.size.height < natural.height + 1 {
            DispatchQueue.main.async {
                let height = max(container.size.height, natural.height + 1)
                container.textView?.maxSize.height = height
                container.size.height = height
            }
        }
        // Uncapped (the Mac default) and already unscrolled: nothing to update.
        guard scrolling || nsView.hasVerticalScroller else { return result }
        DispatchQueue.main.async {
            if nsView.hasVerticalScroller != scrolling {
                nsView.hasVerticalScroller = scrolling
            }
            nsView.refreshEdgeFade()
        }
        return result
    }

    private func apply(to scroll: FadingTextScrollView, coordinator: Coordinator) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let ns = converted(coordinator)
        let fingerprint = Fingerprint(string: ns.string, fontSize: font.pointSize, foreground: foreground, tint: tint)
        if selectionID.flatMap({ document?.container(for: $0) }) == nil, coordinator.fingerprint != fingerprint {
            let isFirstFill = coordinator.fingerprint == nil
            let previous = textView.selectedRange()
            textView.textStorage?.setAttributedString(ns)
            if previous.length > 0, NSMaxRange(previous) <= ns.length {
                textView.setSelectedRange(previous)
            }
            coordinator.fingerprint = fingerprint
            if isFirstFill {
                // A capped bubble starts at its first line (the document view is flipped).
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        textView.linkTextAttributes = [
            .foregroundColor: tint,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
        ]
        scroll.onMoreBelowChange = onMoreBelowChange
        scroll.refreshEdgeFade()
    }

    /// TextKit 1 on purpose. A TextKit 2 view lays out only its viewport, and
    /// nested in the conversation's scroll view it left revealed lines undrawn;
    /// sizing with `boundingRect` also ran up to ~60 pt taller than the view's
    /// own layout on long Markdown replies. Both showed as a blank band under a
    /// reply (2026-10-05). One contiguous engine both measures and draws.
    private static func makeTextView(storage: NSTextStorage) -> NSTextView {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return NSTextView(frame: .zero, textContainer: container)
    }

    /// Same engine and container settings as `makeTextView`, detached so
    /// measurement never touches the live view.
    static func naturalSize(for ns: NSAttributedString, font: NSFont, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: ns)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let lineHeight = ceil(layout.defaultLineHeight(for: font))
        let height = ceil(max(used.height, lineHeight))
        return CGSize(width: min(ceil(max(used.width, 1)), width), height: height)
    }

    private func converted(_ coordinator: Coordinator) -> NSAttributedString {
        if let selectionID, let text = document?.text(for: selectionID) {
            if coordinator.converted !== text {
                coordinator.converted = text
                coordinator.sizes.removeAll()
            }
            return text
        }
        let source = Source(attributed: attributed, fontSize: font.pointSize, foreground: foreground)
        if coordinator.source == source, let converted = coordinator.converted {
            return converted
        }
        let ns = MacMessageTextRenderer.convert(attributed, font: font, foreground: foreground)
        coordinator.source = source
        coordinator.converted = ns
        coordinator.sizes.removeAll()
        return ns
    }

}

/// Shared conversion for measurement, drawing and the conversation text network.
private enum MacMessageTextRenderer {
    static func convert(_ attributed: AttributedString, font: NSFont, foreground: NSColor) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: mutable.length)
        guard full.length > 0 else { return mutable }
        let reference = ChatMarkdown.referenceBodyPointSize
        mutable.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var next = attrs
            if let existing = attrs[.font] as? NSFont {
                let ratio = existing.pointSize / max(reference, 1)
                next[.font] = NSFont(descriptor: existing.fontDescriptor, size: font.pointSize * ratio) ?? font
            } else {
                next[.font] = font
            }
            if attrs[.foregroundColor] == nil {
                next[.foregroundColor] = foreground
            }
            mutable.setAttributes(next, range: range)
        }
        MacMarkdownTable.apply(to: mutable, source: attributed, bodyFont: font)
        return mutable
    }
}

private struct MacConversationTextDocumentKey: EnvironmentKey {
    static let defaultValue: MacConversationTextDocument? = nil
}

private struct MacMessageSelectionIDKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var macConversationTextDocument: MacConversationTextDocument? {
        get { self[MacConversationTextDocumentKey.self] }
        set { self[MacConversationTextDocumentKey.self] = newValue }
    }

    var macMessageSelectionID: Int? {
        get { self[MacMessageSelectionIDKey.self] }
        set { self[MacMessageSelectionIDKey.self] = newValue }
    }
}

struct MacConversationTextSelection: ViewModifier {
    let identity: ObjectIdentifier
    let messages: [RichMessage]
    @Environment(\.sessionTextScale) private var sessionTextScale
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var document = MacConversationTextDocument()

    func body(content: Content) -> some View {
        let sources = messages.compactMap { message -> MacConversationTextDocument.Source? in
            guard let text = message.text, !text.allSatisfy(\.isWhitespace) else { return nil }
            return .init(id: message.seq, text: text, isUser: message.role.lowercased() == "user")
        }
        let font = Typography.sessionUIFont(.bubbleBody, scale: sessionTextScale * interfaceScale)
        let style = MacConversationTextDocument.Style(
            font: font, foreground: .labelColor, userForeground: NSColor(Palette.userBubbleForeground)
        )
        // This updates AppKit reference objects only, never SwiftUI state. The
        // identity/source/style gate makes ordinary view updates a no-op.
        document.update(identity: identity, sources: sources, style: style) { source in
            MacMessageTextRenderer.convert(
                ChatMarkdown.attributed(source.text), font: font,
                foreground: source.isUser ? style.userForeground : style.foreground
            )
        }
        return content
            .environment(\.macConversationTextDocument, document)
            .id(identity)
    }
}
#endif
