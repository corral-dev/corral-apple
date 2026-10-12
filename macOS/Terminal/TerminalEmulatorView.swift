import AppKit
import SwiftTerm
import SwiftUI

/// The agent's own TUI in a pane: SwiftTerm's AppKit terminal fed by the
/// host's raw stream. Scrollback, selection and copy are local; keys, input
/// methods and mouse reports go to the agent; ⌘ shortcuts stay with the app.
struct TerminalEmulator: NSViewRepresentable {
    let stream: RemoteTerminalStream
    let isFocusedPane: Bool
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.conversationScrollReadAction) private var acknowledgeRead

    func makeNSView(context: Context) -> TerminalHostView {
        let view = TerminalHostView()
        view.onManualScroll = acknowledgeRead
        view.updateInterfaceScale(interfaceScale)
        view.bind(stream)
        return view
    }

    func updateNSView(_ view: TerminalHostView, context: Context) {
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
    private static let minimumFit = TerminalGrid(cols: 20, rows: 5)

    private let terminal: StreamTerminalView
    private(set) weak var stream: RemoteTerminalStream?
    private var grid: TerminalGrid?
    private var fontSize = TerminalAppearance.baseSize
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
        stream.sink = self
        stream.isInFront = { [weak self] in self?.isInFront ?? false }
        stream.updateTheme(palette.theme)
        needsLayout = true
        observeReadScrollIfNeeded()
    }

    private func observeReadScrollIfNeeded() {
        guard readScrollMonitor == nil, window != nil, stream != nil else { return }
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
    var inspectionPalette: String { palette == .light ? "light" : "dark" }
    private(set) var inspectionFirstReset: Date?
    var inspectionHasKeyboardFocus: Bool { window?.firstResponder === terminal }
    var inspectionFontSize: CGFloat { fontSize }
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
    private var isInFront: Bool { NSApp.isActive && window?.isKeyWindow == true }

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
        guard let window, window.firstResponder !== terminal else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsKeyboardFocus, let window = self.window else { return }
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
            reportFit()
            applyFittingFont(refreshing: true)
        }
        placeTerminal()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }

    // MARK: - Geometry

    private var cell: CGSize { cellSize(for: fontSize) }

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

    /// Columns at the base font; rows at the font the shared width needs, so a
    /// wider viewer shrinking the font does not leave empty rows below the
    /// agent. Rows never follow a font shrunk for rows (that would run away).
    private func reportFit() {
        guard let stream, bounds.width > 0, bounds.height > 0 else { return }
        let cell = cellSize(for: baseSize)
        let usableWidth = bounds.width - inset * 2 - scrollerReserve
        let usableHeight = bounds.height - inset * 2
        let rowCell = grid.map { cellSize(for: widthFittingFontSize(cols: $0.cols)) } ?? cell
        let fit = TerminalGrid(
            cols: max(Self.minimumFit.cols, Int(usableWidth / cell.width)),
            rows: max(Self.minimumFit.rows, Int(usableHeight / rowCell.height))
        )
        stream.updateFit(fit)
    }

    /// Largest size, in half points from the base down to 9 pt, at which
    /// `cols` fit the pane width.
    private func widthFittingFontSize(cols: Int) -> CGFloat {
        let usableWidth = bounds.width - inset * 2 - scrollerReserve
        var size = baseSize
        while size > TerminalAppearance.minimumSize, CGFloat(cols) * cellSize(for: size).width > usableWidth {
            size -= 0.5
        }
        return max(size, TerminalAppearance.minimumSize)
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
    /// 2026-10-07). Agent panes keep it for the agents' own copy commands.
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let key = stream?.sessionKey, !ProjectShell.isShellKey(key),
              let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// SwiftTerm's view with the host stream's rules: replies the emulator
/// generates while drawing host output are dropped (tmux already answered the
/// agent's queries), mouse reports leave only the focused pane of the key
/// window, and paste goes to the host paste path.
final class StreamTerminalView: SwiftTerm.TerminalView {
    var onPaste: ((String) -> Void)?
    private var feedingHost = false

    func feedFromHost(_ data: Data) {
        feedingHost = true
        defer { feedingHost = false }
        data.withUnsafeBytes { raw in
            feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self)))
        }
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Outside a feed these are mouse reports. Agents such as Claude Code
        // track every pointer move, so only the focused terminal of the key
        // window reports; hovering over a background pane must not type.
        // The wheel is a deliberate gesture: AppKit delivers it to the pane
        // under the pointer, which scrolls whether selected or not, as
        // everywhere else on macOS. (SwiftTerm's scrollWheel cannot be overridden.)
        guard !feedingHost else { return }
        let wheel = NSApp.currentEvent?.type == .scrollWheel
        guard wheel || (window?.isKeyWindow == true && window?.firstResponder === self) else { return }
        super.send(source: source, data: data)
    }

    /// A click into the terminal takes the keyboard, whichever of SwiftTerm's
    /// subviews received it.
    override func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        onPaste?(text)
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

    /// Grid a terminal body of `size` fits at the base font, so a new shell can
    /// start at the size its pane will vote (no resize, no font jump on open).
    static func fittingGrid(for size: CGSize, interfaceScale: CGFloat = 1) -> TerminalGrid? {
        guard size.width > 0, size.height > 0 else { return nil }
        let cell = cellSize(fontSize: baseSize * interfaceScale, scale: nil)
        let cols = Int((size.width - inset * 2 * interfaceScale) / cell.width)
        let rows = Int((size.height - inset * 2 * interfaceScale) / cell.height)
        guard cols >= 20, rows >= 5 else { return nil }
        return TerminalGrid(cols: cols, rows: rows)
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
