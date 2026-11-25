#if os(macOS)
import AppKit
import SwiftUI

/// Inspects an `NSPasteboard` in deterministic priority order so Finder file copies,
/// screenshots/images, and normalized plain text never mask each other.
enum ComposerPasteboard {
    enum Outcome: Equatable {
        case fileURLs([URL])
        case imageData(Data)
        case text(String)
        case none
    }

    private static let explicitRasterTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("org.webmproject.webp"),
    ]

    private static let richTextTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .rtf,
        .html,
    ]

    static func classify(_ pasteboard: NSPasteboard) -> Outcome {
        // 1. Finder file copies also place the bare filename in `.string` and
        //    the file icon in `.tiff`, so file URLs must win first.
        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: urlOptions) as? [URL],
           !urls.isEmpty {
            return .fileURLs(urls)
        }

        // 2. Clipboard screenshots / image copies. Skip explicit raster checks
        //    when RTF + text exist (rich formatted text), or when HTML + text exist
        //    unless text is empty (so Chrome/Safari text copy keeps plain text while
        //    standalone PNG/JPEG copies with URL/filename strings attach the image).
        let types = Set(pasteboard.types ?? [])
        let hasText = !(pasteboard.string(forType: .string)?.isEmpty ?? true)
        let hasRichText = !types.isDisjoint(with: richTextTypes)
        let allowExplicitRaster = !types.contains(.rtf) && (!hasText || !types.contains(.html))
        if allowExplicitRaster {
            for type in explicitRasterTypes {
                if let data = pasteboard.data(forType: type), !data.isEmpty {
                    return .imageData(data)
                }
            }
        }
        if !hasText, !hasRichText, let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
            return .imageData(tiff)
        }

        // 3. Normalized plain text (`\r\n` / `\r` -> `\n`).
        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            let normalized = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return .text(normalized)
        }
        return .none
    }

    static func canPaste(from pasteboard: NSPasteboard) -> Bool {
        classify(pasteboard) != .none
    }
}

/// AppKit TextKit 1 input view for the Mac composer. Using an explicit TextKit 1
/// (`NSLayoutManager`) stack avoids TextKit 2's CJK/ASCII wrap height desync and
/// intercepts `paste:` before AppKit's private field editor swallows screenshots/files.
final class ComposerNSTextView: NSTextView {
    var onTextChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onFollowUp: (() -> Void)?
    var onArrowHistory: ((_ isUp: Bool) -> Bool)?
    var onRecallQueued: (() -> Bool)?
    var onPasteFileURLs: (([URL]) -> Void)?
    var onPasteImageData: ((Data) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onHeightChange: (() -> Void)?
    var onMarkedTextChange: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    var placeholderText: String = "" {
        didSet {
            if oldValue != placeholderText { needsDisplay = true }
        }
    }

    var placeholderColor: NSColor = .placeholderTextColor {
        didSet {
            if oldValue != placeholderColor { needsDisplay = true }
        }
    }

    static func makeTextKit1() -> ComposerNSTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        return ComposerNSTextView(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureDefaults()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDefaults()
    }

    private func configureDefaults() {
        isEditable = true
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        drawsBackground = false
        backgroundColor = .clear
        textContainerInset = .zero
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        minSize = NSSize(width: 0, height: 0)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }

    override var acceptsFirstResponder: Bool {
        isEditable && !isHiddenOrHasHiddenAncestor
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:))
            || item.action == #selector(NSTextView.pasteAsPlainText(_:)) {
            return isEditable && ComposerPasteboard.canPaste(from: .general)
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if !handlePasteboard(.general) {
            NSSound.beep()
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if !handlePasteboard(.general) {
            NSSound.beep()
        }
    }

    @discardableResult
    func handlePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        switch ComposerPasteboard.classify(pasteboard) {
        case .fileURLs(let urls):
            onPasteFileURLs?(urls)
            return true
        case .imageData(let data):
            onPasteImageData?(data)
            return true
        case .text(let normalized):
            insertText(normalized, replacementRange: selectedRange())
            return true
        case .none:
            return false
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable, ComposerPasteboard.canPaste(from: sender.draggingPasteboard) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        handlePasteboard(sender.draggingPasteboard)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onMarkedTextChange?(hasMarkedText())
        onTextChange?(string)
        onHeightChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
        onMarkedTextChange?(hasMarkedText())
        onHeightChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
        onMarkedTextChange?(hasMarkedText())
        onHeightChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if string.isEmpty && !hasMarkedText() && !placeholderText.isEmpty {
            let effectiveFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: effectiveFont,
                .foregroundColor: placeholderColor,
                .paragraphStyle: paragraphStyle,
            ]
            let padding = textContainer?.lineFragmentPadding ?? 0
            let origin = textContainerOrigin
            let lineHeight = ceil(layoutManager?.defaultLineHeight(for: effectiveFont) ?? effectiveFont.pointSize)
            let rect = NSRect(
                x: origin.x + padding,
                y: origin.y,
                width: max(0, bounds.width - origin.x * 2 - padding * 2),
                height: max(bounds.height - origin.y * 2, lineHeight)
            )
            NSAttributedString(string: placeholderText, attributes: attrs)
                .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        super.draw(dirtyRect)
    }

    func applyTypingAttributes(font: NSFont, textColor: NSColor) {
        typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) > 0.5 {
            textContainer?.containerSize = NSSize(width: max(1, newSize.width), height: .greatestFiniteMagnitude)
            onHeightChange?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        // Return / Keypad Enter: Shift+Return inserts newline; Option+Return queues follow-up; plain Return submits.
        if event.keyCode == 36 || event.keyCode == 76 {
            let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if mods == .shift {
                insertNewline(nil)
                return
            }
            if mods == .option, let onFollowUp {
                onFollowUp()
                return
            }
            if mods.isEmpty {
                onSubmit?()
                return
            }
        }
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        if event.keyCode == 126 || event.keyCode == 125 {
            let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if mods == .option, event.keyCode == 126, onRecallQueued?() == true {
                return
            }
            if mods.isEmpty, onArrowHistory?(event.keyCode == 126) == true {
                return
            }
        }
        super.keyDown(with: event)
    }

    func measuredContentHeight(forWidth width: CGFloat) -> (lineHeight: CGFloat, contentHeight: CGFloat) {
        let effectiveFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        guard let layoutManager, let textContainer else {
            let line = ceil(NSLayoutManager().defaultLineHeight(for: effectiveFont))
            return (line, line)
        }
        let targetWidth = max(40, width)
        if abs(textContainer.containerSize.width - targetWidth) > 0.25 {
            textContainer.containerSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = ceil(layoutManager.defaultLineHeight(for: effectiveFont))
        let used = layoutManager.usedRect(for: textContainer).height
        let contentHeight = max(lineHeight, ceil(used + textContainerInset.height * 2))
        return (lineHeight, contentHeight)
    }
}

final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        let targetMin = NSSize(width: width, height: max(0, contentSize.height))
        if textView.minSize != targetMin {
            textView.minSize = targetMin
        }
        let targetHeight: CGFloat
        if let composer = textView as? ComposerNSTextView {
            let (_, contentHeight) = composer.measuredContentHeight(forWidth: width)
            targetHeight = max(targetMin.height, contentHeight)
        } else {
            targetHeight = max(textView.frame.height, targetMin.height)
        }
        if abs(textView.frame.width - width) > 0.5 || abs(textView.frame.height - targetHeight) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: targetHeight))
        }
    }
}

struct MacComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont
    var textColor: NSColor
    var accessibilityLabel: String
    var focusTrigger: Int = 0
    var maxLines: Int = 6
    var onSubmit: () -> Void
    var onFollowUp: (() -> Void)? = nil
    var onArrowHistory: ((_ isUp: Bool) -> Bool)?
    var onRecallQueued: (() -> Bool)? = nil
    var onPasteFileURLs: ([URL]) -> Void
    var onPasteImageData: (Data) -> Void
    var onFocusChange: (Bool) -> Void
    var onMarkedTextChange: ((Bool) -> Void)? = nil

    final class Coordinator {
        var text: Binding<String>
        var lastMeasuredHeight: CGFloat = 0
        var lastFocusTrigger: Int = 0
        var scheduledVerticalScroller: Bool? = nil
        weak var scrollView: NSScrollView?
        weak var textView: ComposerNSTextView?
        var isUpdatingFromSwiftUI = false

        init(text: Binding<String>) {
            self.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .automatic

        let textView = ComposerNSTextView.makeTextKit1()
        textView.placeholderText = placeholder
        textView.placeholderColor = .placeholderTextColor
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.applyTypingAttributes(font: font, textColor: textColor)
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)

        let coordinator = context.coordinator
        coordinator.scrollView = scrollView
        coordinator.textView = textView

        wireCallbacks(textView, coordinator: coordinator)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let textView = coordinator.textView ?? scrollView.documentView as? ComposerNSTextView else {
            return
        }
        wireCallbacks(textView, coordinator: coordinator)

        if textView.placeholderText != placeholder {
            textView.placeholderText = placeholder
        }
        if textView.font != font {
            textView.font = font
            textView.applyTypingAttributes(font: font, textColor: textColor)
            textView.needsDisplay = true
            scrollView.invalidateIntrinsicContentSize()
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
            textView.applyTypingAttributes(font: font, textColor: textColor)
        }
        if textView.accessibilityLabel() != accessibilityLabel {
            textView.setAccessibilityLabel(accessibilityLabel)
        }
        if coordinator.lastFocusTrigger != focusTrigger {
            coordinator.lastFocusTrigger = focusTrigger
            if let window = textView.window, textView.acceptsFirstResponder,
               window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }

        // Preserve IME composition: never replace storage while marked text exists.
        if !textView.hasMarkedText(), textView.string != text {
            coordinator.isUpdatingFromSwiftUI = true
            let selected = textView.selectedRange()
            let nsString = text as NSString
            let clampedLoc = min(selected.location, nsString.length)
            let clampedLen = min(selected.length, nsString.length - clampedLoc)
            textView.string = text
            textView.applyTypingAttributes(font: font, textColor: textColor)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
            textView.needsDisplay = true
            if text.isEmpty {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            coordinator.isUpdatingFromSwiftUI = false
            scrollView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? ComposerNSTextView else {
            return nil
        }
        if proposal.width == 0 {
            let line = ceil(textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize)
            return CGSize(width: 1, height: line)
        }
        let width = max(40, proposal.width ?? (scrollView.frame.width > 1 ? scrollView.frame.width : 200))
        let (lineHeight, contentHeight) = textView.measuredContentHeight(forWidth: width)
        let maxHeight = ceil(lineHeight * CGFloat(max(1, maxLines)))
        let clamped = min(max(lineHeight, contentHeight), maxHeight)
        let needsScroll = contentHeight > maxHeight + 0.5
        if context.coordinator.scheduledVerticalScroller != needsScroll {
            context.coordinator.scheduledVerticalScroller = needsScroll
            DispatchQueue.main.async {
                if scrollView.hasVerticalScroller != needsScroll {
                    scrollView.hasVerticalScroller = needsScroll
                }
                if scrollView.scrollerStyle != .overlay {
                    scrollView.scrollerStyle = .overlay
                }
            }
        }
        context.coordinator.lastMeasuredHeight = clamped
        return CGSize(width: width, height: clamped)
    }

    private func wireCallbacks(_ textView: ComposerNSTextView, coordinator: Coordinator) {
        textView.onTextChange = { [weak coordinator] updated in
            guard let coordinator, !coordinator.isUpdatingFromSwiftUI else { return }
            if coordinator.text.wrappedValue != updated {
                coordinator.text.wrappedValue = updated
            }
        }
        textView.onHeightChange = { [weak coordinator, weak textView] in
            guard let coordinator, let scrollView = coordinator.scrollView, let textView else { return }
            let width = max(40, scrollView.frame.width > 1 ? scrollView.frame.width : textView.frame.width)
            let (lineHeight, contentHeight) = textView.measuredContentHeight(forWidth: width)
            let maxHeight = ceil(lineHeight * CGFloat(max(1, maxLines)))
            let clamped = min(max(lineHeight, contentHeight), maxHeight)
            if abs(clamped - coordinator.lastMeasuredHeight) > 0.5 {
                scrollView.invalidateIntrinsicContentSize()
            }
        }
        textView.onSubmit = onSubmit
        textView.onFollowUp = onFollowUp
        textView.onArrowHistory = onArrowHistory
        textView.onRecallQueued = onRecallQueued
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onPasteImageData = onPasteImageData
        textView.onFocusChange = onFocusChange
        textView.onMarkedTextChange = onMarkedTextChange
    }
}
#endif
