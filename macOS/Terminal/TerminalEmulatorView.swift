import AppKit
import SwiftTerm
import SwiftUI

/// The agent's own TUI in a pane: SwiftTerm's AppKit terminal fed by the
/// host's raw stream. Scrollback, selection and copy are local; keys, input
/// methods and mouse reports go to the agent; ⌘ shortcuts stay with the app.
struct TerminalEmulator: NSViewRepresentable {
    let stream: RemoteTerminalStream
    let isFocusedPane: Bool
    let isPresented: Bool
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.conversationScrollReadAction) private var acknowledgeRead

    func makeNSView(context: Context) -> TerminalHostView {
        let view = TerminalHostView()
        view.setPresented(isPresented)
        view.onManualScroll = acknowledgeRead
        view.updateInterfaceScale(interfaceScale)
        view.bind(stream)
        return view
    }

    func updateNSView(_ view: TerminalHostView, context: Context) {
        view.setPresented(isPresented)
        view.onManualScroll = acknowledgeRead
        if view.stream !== stream {
            view.bind(stream)
        }
        view.updateInterfaceScale(interfaceScale)
        view.wantsKeyboardFocus = isFocusedPane
    }

    static func dismantleNSView(_ view: TerminalHostView, coordinator: ()) {
        view.unbind()
    }

    /// Take whatever the split offers: the host grid must never become the
    /// pane's minimum width (it would push the whole window out of bounds).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 320)
    }
}

/// Hosts the emulator at the host's grid. Reports the grid this pane fits at
/// the base font so the host can size the shared pane to the viewer the user
/// used last; while another viewer's larger grid is in charge the font shrinks
/// to fit (to 9 pt), and whatever still does not fit is cropped right and top,
/// keeping the agent's input row.
final class TerminalHostView: NSView, TerminalStreamSink, TerminalViewDelegate {
    private var interfaceScale: CGFloat = 1
    private var baseSize: CGFloat { TerminalAppearance.baseSize * interfaceScale }
    private var inset: CGFloat { TerminalAppearance.inset * interfaceScale }
    // The host withdraws votes below 40 × 10 to avoid narrow wraps in shared
    // scrollback. A 220 pt split pane can fit fewer than 40 cols at 13 pt.
    private static let minimumFit = TerminalGrid(cols: 40, rows: 10)

    private let terminal: StreamTerminalView
    private(set) weak var stream: RemoteTerminalStream?
    private var grid: TerminalGrid?
    private var fontSize = TerminalAppearance.baseSize
    private var presentationEnabled = true
    var onManualScroll: (@MainActor @Sendable () -> Void)?
    private var readScrollMonitor: Any?
    private var frontObservers: [NSObjectProtocol] = []

    init() {
        terminal = StreamTerminalView(frame: .zero, font: TerminalAppearance.font(size: TerminalAppearance.baseSize))
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        terminal.terminalDelegate = self
        terminal.onPaste = { [weak self] text in
            self?.terminal.scroll(toPosition: 1)
            self?.stream?.input.paste(text)
        }
        addSubview(terminal)
        // A terminal pane shows no scroll bar (owner decision 2026-10-06).
        // SwiftTerm's own scroller reserves a column and, outside a scroll
        // view, never hides; a hidden one reserves nothing.
        terminal.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        applyPalette()
        #if DEBUG
        Self.inspectionLatest = self
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func updateInterfaceScale(_ value: CGFloat) {
        let next = min(max(value, 0.8), 1.5)
        guard next != interfaceScale else { return }
        interfaceScale = next
        // Layout and the stream's existing fit debounce coalesce repeated keys.
        needsLayout = true
    }

    func bind(_ stream: RemoteTerminalStream) {
        self.stream?.sink = nil
        self.stream = stream
        grid = nil
        lastReportedFit = nil
        stream.sink = self
        stream.isInFront = { [weak self] in self?.isInFront ?? false }
        stream.updateTheme(palette.theme)
        needsLayout = true
        observeReadScrollIfNeeded()
    }

    private func observeReadScrollIfNeeded() {
        guard presentationEnabled, readScrollMonitor == nil, window != nil, stream != nil else { return }
        readScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Observe only the terminal actually under the pointer, including an
            // unfocused pane; overlays, other windows and host output cannot read it.
            if let self, let window = self.window, event.window === window,
               event.scrollingDeltaY != 0, let content = window.contentView,
               let target = content.hitTest(content.convert(event.locationInWindow, from: nil)),
               target === self.terminal || target.isDescendant(of: self.terminal) {
                self.onManualScroll?()
            }
            return event
        }
    }

    private func removeReadScrollMonitor() {
        if let readScrollMonitor { NSEvent.removeMonitor(readScrollMonitor) }
        readScrollMonitor = nil
    }

    func terminalRevealPrompt(_ query: String) -> Bool { terminal.revealPrompt(query) }
    func terminalRevealPrompt(_ query: String, occurrence: Int, total: Int) -> Bool {
        terminal.revealPrompt(query, occurrence: occurrence, total: total)
    }

    // MARK: - Appearance

    private var palette = TerminalPalette.dark

    /// Light or dark with the window; the host learns the colours so agents
    /// that query the terminal background pick the matching theme.
    private func applyPalette() {
        let next = TerminalPalette.matching(effectiveAppearance)
        let changed = next != palette
        palette = next
        layer?.backgroundColor = next.background.cgColor
        next.apply(to: terminal)
        if changed { stream?.updateTheme(next.theme) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    #if DEBUG
    static weak var inspectionLatest: TerminalHostView?
    private var lastInspectedFit: TerminalGrid?
    var inspectionPalette: String { palette == .light ? "light" : "dark" }
    private(set) var inspectionFirstReset: Date?
    var inspectionHasKeyboardFocus: Bool { window?.firstResponder === terminal }
    var inspectionFontSize: CGFloat { fontSize }
    var inspectionUsesMetal: Bool { terminal.isUsingMetalRenderer }
    var inspectionBottomVisible: Bool { terminal.frame.maxY <= bounds.maxY - inset + 1 }
    var inspectionVisibleText: [String] {
        let emulator = terminal.getTerminal()
        return (0..<emulator.rows).compactMap { row in
            emulator.getLine(row: row)?.translateToString(trimRight: true)
        }
    }
    var inspectionVisibleRows: Int {
        let emulator = terminal.getTerminal()
        return (0..<emulator.rows).filter { row in
            !(emulator.getLine(row: row)?.translateToString(trimRight: true) ?? "").isEmpty
        }.count
    }

    /// Delivers key-down events through the window, as the keyboard does,
    /// so focus and SwiftTerm's key handling are both exercised.
    func inspectionPressKeys(_ characters: [String]) {
        guard let window else { return }
        for character in characters {
            let keyCode: UInt16 = character == "\u{7f}" ? 51 : (character == "\r" ? 36 : 0)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode
            ) else { continue }
            window.sendEvent(event)
        }
    }

    func inspectionScrollUp(lines: Int) { terminal.scrollUp(lines: lines) }
    var inspectionScrollPosition: Double { terminal.scrollPosition }

    func inspectionContains(_ text: String) -> Bool {
        let emulator = terminal.getTerminal()
        let visible = (0..<emulator.rows).compactMap { row in
            emulator.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
        }.joined()
        return visible.contains(text)
    }
    #endif

    /// The window the user is looking at: the host pane follows this view.
    private var isInFront: Bool { presentationEnabled && NSApp.isActive && window?.isKeyWindow == true }

    func setPresented(_ presented: Bool) {
        guard presentationEnabled != presented else { return }
        presentationEnabled = presented
        isHidden = !presented
        if presented {
            observeReadScrollIfNeeded()
            if wantsKeyboardFocus { focusTerminal() }
        } else {
            if let window, let responder = window.firstResponder as? NSView,
               responder === terminal || responder.isDescendant(of: terminal) {
                window.makeFirstResponder(nil)
            }
            removeReadScrollMonitor()
        }
    }

    /// Coming back to this window (it becomes key, or the app is activated
    /// with it key) takes the shared agent grid back from the TUI or another view.
    private func observeFront() {
        frontObservers.forEach(NotificationCenter.default.removeObserver)
        frontObservers = []
        guard let window else { return }
        let claim: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isInFront else { return }
                self.stream?.claimSize()
            }
        }
        frontObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: claim
            ),
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: claim
            ),
        ]
    }

    func unbind() {
        frontObservers.forEach(NotificationCenter.default.removeObserver)
        frontObservers = []
        removeReadScrollMonitor()
        onManualScroll = nil
        stream?.sink = nil
        stream = nil
    }

    /// The focused pane's terminal takes the keyboard, including when it is
    /// created already focused (switching a pane to terminal view), before it
    /// has a window.
    var wantsKeyboardFocus = false {
        didSet { if wantsKeyboardFocus { focusTerminal() } }
    }

    private func focusTerminal() {
        guard presentationEnabled, let window, window.firstResponder !== terminal else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationEnabled, self.wantsKeyboardFocus,
                  let window = self.window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeReadScrollMonitor()
        observeReadScrollIfNeeded()
        observeFront()
        // SwiftTerm's renderer stays on CoreGraphics: its experimental Metal
        // path blocks the main thread ~0.4 s per terminal while it searches
        // every bundle for its shader library, and can present nothing.
        guard window != nil, wantsKeyboardFocus else { return }
        focusTerminal()
    }

    override func layout() {
        super.layout()
        // Dragging the window edge or a split divider only moves the grid;
        // fitting, the font and the host size vote wait for the drag to end.
        if !inLiveResize {
            let voteChanged = reportFit()
            // A fresh vote from the front window always wins the shared pane
            // (most-recently-used), so its snapshot is already on the way:
            // fitting the still-stale grid now would transiently shrink the
            // font, then the snapshot grows it back ("shrink then enlarge" on
            // every window shrink). Crop via placeTerminal until the snapshot
            // lands instead. A background vote never claims the grid, so it
            // still fits whatever grid is current.
            if !(voteChanged && isInFront) {
                applyFittingFont(refreshing: true)
            }
        }
        placeTerminal()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }

    // MARK: - Geometry

    private var cell: CGSize { cellSize(for: fontSize) }
    /// Last grid voted to the host: layout() runs on every drag/scroll step,
    /// but the host only needs to hear about actual grid changes.
    private var lastReportedFit: TerminalGrid?
    /// Cell size exactly as SwiftTerm computes it (advance of "W", line height
    /// snapped to the backing scale), so a frame of N cells yields N columns.
    private func cellSize(for size: CGFloat) -> CGSize {
        TerminalAppearance.cellSize(fontSize: size, scale: window?.backingScaleFactor)
    }

    /// Width SwiftTerm keeps beside the cells for its scroller.
    private var scrollerReserve: CGFloat {
        let terminalGrid = terminal.getTerminal()
        let optimal = terminal.getOptimalFrameSize()
        return max(0, optimal.width - cell.width * CGFloat(terminalGrid.cols))
    }

    /// Columns at the base font, floored at the host's accepted minimum; rows
    /// at the font those columns need. A narrow pane must not vote fewer than
    /// 40 cols (the host would withdraw it and keep another viewer's height).
    /// Rows never follow a font shrunk for rows (that would run away).
    /// Returns whether a new vote was sent (used to skip fitting the stale
    /// grid while its snapshot is on the way; see layout()).
    @discardableResult
    private func reportFit() -> Bool {
        guard let stream, bounds.width > 0, bounds.height > 0 else { return false }
        let cell = cellSize(for: baseSize)
        let usableWidth = bounds.width - inset * 2 - scrollerReserve
        let usableHeight = bounds.height - inset * 2
        let cols = max(Self.minimumFit.cols, Int(usableWidth / cell.width))
        let rowCell = cellSize(for: widthFittingFontSize(cols: cols))
        let fit = TerminalGrid(
            cols: cols,
            rows: max(Self.minimumFit.rows, Int(usableHeight / rowCell.height))
        )
        guard fit != lastReportedFit else { return false }
        lastReportedFit = fit
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalFit"), fit != lastInspectedFit {
            lastInspectedFit = fit
            debugTrace(String(format: "terminal fit pane %.0fx%.0f, vote %dx%d, row cell %.1f, front %@",
                              bounds.width, bounds.height, fit.cols, fit.rows, rowCell.height,
                              isInFront ? "yes" : "no"))
        }
        #endif
        stream.updateFit(fit)
        return true
    }

    /// Largest size, in half points from the base down to 9 pt, at which
    /// `cols` fit the pane width.
    private func widthFittingFontSize(cols: Int) -> CGFloat {
        let usableWidth = bounds.width - inset * 2 - scrollerReserve
        return TerminalAppearance.widthFittingFontSize(
            cols: cols, usableWidth: usableWidth, baseSize: baseSize,
            scale: window?.backingScaleFactor
        )
    }

    /// Largest size, in half points from the base down to 9 pt, at which the
    /// host grid fits this pane.
    private func fittingFontSize(for grid: TerminalGrid) -> CGFloat {
        let usableWidth = bounds.width - inset * 2 - scrollerReserve
        let usableHeight = bounds.height - inset * 2
        var size = baseSize
        while size > TerminalAppearance.minimumSize {
            let cell = cellSize(for: size)
            if CGFloat(grid.cols) * cell.width <= usableWidth, CGFloat(grid.rows) * cell.height <= usableHeight {
                break
            }
            size -= 0.5
        }
        return max(size, TerminalAppearance.minimumSize)
    }

    /// SwiftTerm resets terminal modes when its font changes, so a change
    /// outside a snapshot asks the host for a fresh one.
    private func applyFittingFont(refreshing: Bool) {
        guard let grid, bounds.width > 0, bounds.height > 0 else { return }
        let size = fittingFontSize(for: grid)
        guard size != fontSize else { return }
        fontSize = size
        terminal.font = TerminalAppearance.font(size: size)
        placeTerminal()
        if refreshing { stream?.refreshSnapshot() }
    }

    private func placeTerminal() {
        let cell = cell
        let size: CGSize
        if let grid {
            // Half a point of slack so SwiftTerm's floor() lands on the grid exactly.
            size = CGSize(
                width: CGFloat(grid.cols) * cell.width + scrollerReserve + 0.5,
                height: CGFloat(grid.rows) * cell.height + 0.5
            )
        } else {
            size = CGSize(width: bounds.width - inset * 2, height: bounds.height - inset * 2)
        }
        // Too tall even at the smallest font: keep the bottom (the agent's
        // input row) and crop the top.
        let overflow = size.height - (bounds.height - inset * 2)
        let origin = CGPoint(x: inset, y: overflow > 0 ? inset - overflow : inset)
        let frame = CGRect(origin: origin, size: size)
        if terminal.frame != frame {
            terminal.frame = frame
        }
    }

    // MARK: - TerminalStreamSink

    func terminalReset(grid: TerminalGrid, data: Data) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalFit") {
            debugTrace("terminal snapshot grid \(grid.cols)x\(grid.rows)")
        }
        #endif
        #if DEBUG
        if inspectionFirstReset == nil { inspectionFirstReset = Date() }
        #endif
        self.grid = grid
        applyFittingFont(refreshing: false)
        placeTerminal()
        if !inLiveResize { reportFit() }
        if terminal.getTerminal().cols != grid.cols || terminal.getTerminal().rows != grid.rows {
            terminal.resize(cols: grid.cols, rows: grid.rows)
        }
        terminal.getTerminal().resetToInitialState()
        terminal.feedFromHost(data)
    }

    func terminalFeed(_ data: Data) {
        terminal.feedFromHost(data)
    }

    // MARK: - TerminalViewDelegate

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        #if DEBUG
        debugTrace("emulator send \(data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " "))")
        #endif
        // Typing returns to the live screen, as in iTerm2 and Terminal.app;
        // SwiftTerm only scrolls when the caret is off screen, so after a
        // small scroll back a shell `clear` drew its prompt rows below the top.
        if NSApp.currentEvent?.type == .keyDown { terminal.scroll(toPosition: 1) }
        stream?.input.send(data)
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        // The host decides the grid; fits are reported from this view's bounds.
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    /// OSC 52 from host output. Project shells run arbitrary programs, so they
    /// may not write the clipboard (iTerm2's default; security review
    /// 2026-10-07). Agent panes keep it for the agents' own copy commands, but
    /// only while this pane is the focused, frontmost view: background output
    /// must never silently replace what the person copied.
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let key = stream?.sessionKey, !ProjectShell.isShellKey(key),
              presentationEnabled, wantsKeyboardFocus, isInFront,
              content.count <= 1_048_576,
              let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Terminal font. Colours live in `TerminalPalette`.
enum TerminalAppearance {
    static let baseSize: CGFloat = 13
    static let minimumSize: CGFloat = 9
    /// Margin between the pane edge and the cell grid.
    static let inset: CGFloat = 6

    /// Cell size exactly as SwiftTerm computes it (advance of "W", line height
    /// snapped to the backing scale), so a frame of N cells yields N columns.
    static func cellSize(fontSize: CGFloat, scale: CGFloat?) -> CGSize {
        let font = font(size: fontSize)
        let scale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let ctFont = font as CTFont
        let height = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        return CGSize(
            width: max(1, (width * scale).rounded() / scale),
            height: max(1, ceil(height * scale) / scale)
        )
    }

    static func widthFittingFontSize(cols: Int, usableWidth: CGFloat, baseSize: CGFloat, scale: CGFloat?) -> CGFloat {
        var size = baseSize
        while size > minimumSize, CGFloat(cols) * cellSize(fontSize: size, scale: scale).width > usableWidth {
            size -= 0.5
        }
        return max(size, minimumSize)
    }

    /// Initial grid for a new shell, using the same host minimum as the live
    /// pane vote. Narrow slots start at 40 columns and fit with a smaller font.
    static func fittingGrid(for size: CGSize, interfaceScale: CGFloat = 1) -> TerminalGrid? {
        guard size.width > 0, size.height > 0 else { return nil }
        let cell = cellSize(fontSize: baseSize * interfaceScale, scale: nil)
        let cols = Int((size.width - inset * 2 * interfaceScale) / cell.width)
        let rows = Int((size.height - inset * 2 * interfaceScale) / cell.height)
        guard cols >= 20, rows >= 5 else { return nil }
        let votedCols = max(40, cols)
        let rowFontSize = widthFittingFontSize(
            cols: votedCols, usableWidth: size.width - inset * 2 * interfaceScale,
            baseSize: baseSize * interfaceScale, scale: nil
        )
        let rowCell = cellSize(fontSize: rowFontSize, scale: nil)
        let votedRows = max(10, Int((size.height - inset * 2 * interfaceScale) / rowCell.height))
        return TerminalGrid(cols: votedCols, rows: votedRows)
    }

    static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Pane background around the emulator, following the view's appearance.
    static let background = NSColor(name: "CorralTerminalBackground") { appearance in
        TerminalPalette.matching(appearance).background
    }
}

/// The shared `TerminalColorScheme` as AppKit colours for one appearance.
struct TerminalPalette: Equatable {
    let scheme: TerminalColorScheme

    var background: NSColor { Self.color(scheme.background) }
    var foreground: NSColor { Self.color(scheme.foreground) }

    static func == (lhs: TerminalPalette, rhs: TerminalPalette) -> Bool {
        lhs.scheme.background == rhs.scheme.background && lhs.scheme.foreground == rhs.scheme.foreground
    }

    static let dark = TerminalPalette(scheme: .dark)
    static let light = TerminalPalette(scheme: .light)

    static func matching(_ appearance: NSAppearance) -> TerminalPalette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// `#rrggbb` pair reported to the host.
    var theme: TerminalTheme { scheme.theme }

    @MainActor
    func apply(to view: SwiftTerm.TerminalView) {
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = NSColor.controlAccentColor
        view.installColors(scheme.ansi.map { SwiftTerm.Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue)) })
    }

    private static func color(_ rgb: TerminalColorScheme.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}
