import AppKit
import SwiftTerm

/// SwiftTerm's view with the host stream's rules: replies the emulator
/// generates while drawing host output are dropped (tmux already answered the
/// agent's queries), mouse reports go to the host under the pane's focus
/// rule, and paste goes to the host paste path.
final class StreamTerminalView: SwiftTerm.TerminalView {
    var onPaste: ((String) -> Void)?
    var contextMenuCellSize: CGSize = .zero

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isText(at: convert(event.locationInWindow, from: nil)) else {
            return paneSessionContextMenu()
        }
        let menu = NSMenu()
        for (title, action) in [
            (String(localized: "action.copy"), #selector(copy(_:))),
            (String(localized: "composer.key.paste"), #selector(paste(_:))),
            (String(localized: "action.select_all"), #selector(selectAll(_:)))
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    func isText(at point: NSPoint) -> Bool {
        guard bounds.contains(point), contextMenuCellSize.width > 0, contextMenuCellSize.height > 0 else {
            return false
        }
        let col = Int(point.x / contextMenuCellSize.width)
        let row = Int((bounds.height - point.y) / contextMenuCellSize.height)
        guard let snapshot = terminalContentSnapshot(region: .viewport),
              snapshot.rows.indices.contains(row) else { return false }
        let cells = snapshot.rows[row].cells
        guard cells.indices.contains(col) else { return false }
        let cell = cells[col].width == 0 && col > 0 ? cells[col - 1] : cells[col]
        return !cell.text.isEmpty && cell.text != "\0" && !cell.text.allSatisfy(\.isWhitespace)
    }

    /// The person's mouse reports (wheel, click, drag, motion) with the type
    /// of the event that produced them.
    var onMouseReport: ((ArraySlice<UInt8>, NSEvent.EventType?) -> Void)?
    /// True only during the synchronous parse of host output, on the main thread.
    private var feedingHost = false

    func feedFromHost(_ data: Data) {
        #if DEBUG
        Self.feedCount += 1
        Self.feedBytes += data.count
        #endif
        feedingHost = true
        defer { feedingHost = false }
        feedPreservingSelection(data)
    }

    #if DEBUG
    /// Streaming diagnostics; compiled out of Release. `setNeedsDisplay` is the
    /// row range SwiftTerm asks AppKit to repaint, so counting its height in
    /// rows tells whether a frame's damage is a few rows or the whole screen.
    static var feedCount = 0
    static var feedBytes = 0
    static var invalidations = 0
    static var invalidatedRows = 0.0
    static var totalRows = 0

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        Self.invalidations += 1
        let rows = max(1, terminalDimensions.rows)
        Self.totalRows = rows
        let rowHeight = bounds.height > 0 ? bounds.height / CGFloat(rows) : 0
        if rowHeight > 0 {
            Self.invalidatedRows += min(Double(rows), Double(invalidRect.height / rowHeight))
        }
        super.setNeedsDisplay(invalidRect)
    }
    #endif

    /// SwiftTerm 1.99 sends parser replies and mouse reports through this one
    /// callback (keyboard input uses TerminalViewDelegate). Replies arise only
    /// while host output is parsed, synchronously on the main thread; tmux
    /// already answered them, so they are dropped. Anything else comes from
    /// SwiftTerm's own mouse handlers on the main thread, inside its terminal
    /// lock: capture the dispatching event now and deliver after the lock.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard !feedingHost, onMouseReport != nil else { return }
            let bytes = Array(data), type = NSApp.currentEvent?.type
            DispatchQueue.main.async { [weak self] in self?.onMouseReport?(bytes[...], type) }
        }
    }

    /// A click into the terminal takes the keyboard, whichever of SwiftTerm's
    /// subviews received it.
    override func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    // MARK: - IME anchoring under Metal

    /// SwiftTerm's Metal path draws the cursor itself and leaves `caretView`
    /// (which `firstRect` and the marked-text overlay anchor to) frozen at
    /// its pre-Metal frame, so the input-method candidate window and the
    /// inline composition preview appear at a stale position. While the Metal
    /// renderer is active, anchor both to the live cursor from the content
    /// snapshot instead; otherwise defer to SwiftTerm.
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        if isUsingMetalRenderer, let cursor = liveCursorRect(), let window {
            return window.convertToScreen(convert(cursor, to: nil))
        }
        return super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        guard isUsingMetalRenderer, let cursor = liveCursorRect() else { return }
        repositionMarkedTextOverlay(cursorMaxY: cursor.maxY, caretX: cursor.minX, cellHeight: cursor.height)
    }

    /// Cursor cell in this view's coordinates, mirroring SwiftTerm's cursor
    /// math (non-flipped: row 0 at the top). Nil when the snapshot is
    /// unavailable or the cursor is outside the visible viewport, in which
    /// case the caller falls back to SwiftTerm's answer.
    private func liveCursorRect() -> NSRect? {
        guard let snapshot = terminalContentSnapshot(region: .viewport),
              let top = snapshot.rows.first else { return nil }
        let screenRow = snapshot.cursorRow - top.absoluteRow
        guard screenRow >= 0, screenRow < snapshot.rows.count else { return nil }
        let row = snapshot.rows[screenRow]
        guard row.absoluteRow == snapshot.cursorRow else { return nil }
        let col = min(max(0, snapshot.cursorColumn), row.cells.count)
        let xCells = row.cells.prefix(col).reduce(0) { $0 + max(0, $1.width) }
        let cell = TerminalAppearance.cellSize(fontSize: font.pointSize, scale: window?.backingScaleFactor)
        let width = col < row.cells.count
            ? CGFloat(max(1, row.cells[col].width)) * cell.width
            : cell.width
        return NSRect(
            x: CGFloat(xCells) * cell.width,
            y: bounds.height - CGFloat(screenRow + 1) * cell.height,
            width: width,
            height: cell.height
        )
    }

    /// The overlay is SwiftTerm-private, so it is found by class name and
    /// only its stale origin/exclusion (both derived from the frozen caret)
    /// are corrected; size and text stay as SwiftTerm laid them out.
    private func repositionMarkedTextOverlay(cursorMaxY: CGFloat, caretX: CGFloat, cellHeight: CGFloat) {
        guard let overlay = subviews.first(where: {
            $0 is NSTextView && NSStringFromClass(type(of: $0)).contains("DictationOverlay")
        }) as? NSTextView,
              let container = overlay.textContainer else { return }
        var frame = overlay.frame
        frame.origin.y = cursorMaxY - frame.height
        overlay.frame = frame
        let overlayX = frame.minX
        let exclusionWidth = max(0, caretX - overlayX)
        container.exclusionPaths = exclusionWidth > 0
            ? [NSBezierPath(rect: NSRect(x: 0, y: 0, width: exclusionWidth, height: cellHeight + 1))]
            : []
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        // Cap a single paste at 1 MiB: larger blobs go through the host paste
        // path in chunks via TerminalInputSender, but one paste event must not
        // queue gigabytes behind the typing order.
        let capped = text.count > 1_048_576 ? String(text.prefix(1_048_576)) : text
        onPaste?(capped)
    }
}

