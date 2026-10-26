import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm's UIKit terminal fed by a host shell or agent stream. The view's own grid
/// (its frame at the phone font) is the size it votes; the host makes the
/// latest active viewer's grid the shell's, so typing here sizes the shell to
/// the phone. SwiftTerm's keyboard accessory supplies Esc, Ctrl, Tab and arrows.
struct ShellTerminalView: UIViewRepresentable {
    let stream: RemoteTerminalStream
    var isPresented = true
    var allowsInput = true
    var isAgent = false

    func makeUIView(context: Context) -> ShellTerminalHost {
        let view = ShellTerminalHost(frame: .zero)
        view.configure(presented: isPresented, allowsInput: allowsInput, isAgent: isAgent)
        view.bind(stream)
        return view
    }

    func updateUIView(_ view: ShellTerminalHost, context: Context) {
        view.configure(presented: isPresented, allowsInput: allowsInput, isAgent: isAgent)
        if view.stream !== stream { view.bind(stream) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShellTerminalHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 400)
    }

    static func dismantleUIView(_ view: ShellTerminalHost, coordinator: ()) {
        view.unbind()
    }
}

final class ShellTerminalHost: SwiftTerm.TerminalView, TerminalStreamSink, TerminalViewDelegate {
    static let fontSize: CGFloat = 11

    private(set) weak var stream: RemoteTerminalStream?
    private var feedingHost = false
    private var presented = true
    private var allowsInput = true
    private var isAgent = false
    private var scheme = TerminalColorScheme.dark
    private var touchInteraction: TerminalTouchInteraction?
    private var wheelBytes: [UInt8]?

    override init(frame: CGRect) {
        super.init(frame: frame, font: UIFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular))
        terminalDelegate = self
        changeScrollback(10_000)
        touchInteraction = TerminalTouchInteraction(terminal: self)
        applyScheme()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShellTerminalHost, _: UITraitCollection) in
            view.applyScheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func bind(_ stream: RemoteTerminalStream) {
        self.stream?.sink = nil
        self.stream = stream
        stream.sink = self
        stream.updateTheme(scheme.theme)
        lastReportedFit = nil
        scheduleFit()
    }

    func terminalRevealPrompt(_ query: String) -> Bool { revealPrompt(query) }
    func terminalRevealPrompt(_ query: String, occurrence: Int, total: Int) -> Bool {
        revealPrompt(query, occurrence: occurrence, total: total)
    }

    func unbind() {
        touchInteraction?.reset()
        cancelPendingFit()
        lastReportedFit = nil
        stream?.sink = nil
        stream = nil
    }

    func configure(presented: Bool, allowsInput: Bool, isAgent: Bool) {
        let revealed = !self.presented && presented
        self.presented = presented
        self.allowsInput = allowsInput
        self.isAgent = isAgent
        isHidden = !presented
        accessibilityElementsHidden = !presented
        if !presented || !allowsInput { _ = resignFirstResponder() }
        if !presented {
            touchInteraction?.reset()
            cancelPendingFit()
        }
        if revealed { scheduleFit() }
    }

    override var canBecomeFirstResponder: Bool { presented && allowsInput && super.canBecomeFirstResponder }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleFit()
    }

    override func paste(_ sender: Any?) {
        guard presented, allowsInput, stream?.phase == .live, let text = UIPasteboard.general.string else { return }
        touchInteraction?.cancelScrolling()
        scroll(toPosition: 1)
        stream?.input.paste(text)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Project shells focus on open; an agent terminal focuses only on a tap.
        if window != nil, !isAgent {
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        }
    }

    private func applyScheme() {
        let next: TerminalColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let changed = next.background != scheme.background
        scheme = next
        nativeBackgroundColor = Self.color(next.background)
        nativeForegroundColor = Self.color(next.foreground)
        installColors(next.ansi.map { SwiftTerm.Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue)) })
        keyboardAppearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        if changed { stream?.updateTheme(next.theme) }
    }

    private static func color(_ rgb: TerminalColorScheme.RGB) -> UIColor {
        UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    /// Coalesced size vote (chat/terminal switch fix, 2026-10-15): removing the
    /// chat composer grows this viewport by the composer height in the same
    /// transaction that reveals the terminal. Voting every layout pass attaches
    /// the host at the pre-expansion grid, paints a short grid, then resizes to
    /// the settled grid: a composer-height blank strip at the bottom that fills
    /// a moment later. Debouncing to the settled bounds makes the host attach
    /// once at the final grid; a retained emulator keeps its old screen while
    /// the fresh snapshot is on the way. Delay matches the shared stream's
    /// 150 ms resize settle.
    private var lastReportedFit: TerminalGrid?
    private func scheduleFit() {
        guard presented, !feedingHost, bounds.width > 0, bounds.height > 0 else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(deliverFit), object: nil)
        perform(#selector(deliverFit), with: nil, afterDelay: 0.15)
    }

    private func cancelPendingFit() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(deliverFit), object: nil)
    }

    @objc private func deliverFit() {
        guard presented, !feedingHost, bounds.width > 0, bounds.height > 0 else { return }
        let emulator = terminalDimensions
        let optimal = getOptimalFrameSize()
        let cellWidth = optimal.width / CGFloat(max(1, emulator.cols))
        let cellHeight = optimal.height / CGFloat(max(1, emulator.rows))
        guard cellWidth > 0, cellHeight > 0 else { return }
        // Fit derives from the local viewport, never a received desktop grid.
        let fit = TerminalGrid(
            cols: max(isAgent ? 40 : 20, Int(bounds.width / cellWidth)),
            rows: max(isAgent ? 10 : 5, Int(bounds.height / cellHeight))
        )
        guard fit != lastReportedFit else { return }
        lastReportedFit = fit
        stream?.updateFit(fit)
    }

    // MARK: - TerminalStreamSink

    /// Grid of the last host snapshot; the emulator may already have re-wrapped
    /// itself to new bounds, so a reader's row is compared against this.
    private var hostGrid: TerminalGrid?

    func terminalReset(grid: TerminalGrid, data: Data) {
        feedingHost = true
        defer { feedingHost = false }
        let emulator = terminalDimensions
        let hostGridChanged = hostGrid.map { $0 != grid } ?? false
        hostGrid = grid
        touchInteraction?.cancelScrolling()
        preservingViewportDuringSnapshot(hostGridChanged: hostGridChanged) {
            if emulator.cols != grid.cols || emulator.rows != grid.rows {
                resize(cols: grid.cols, rows: grid.rows)
            }
            resetToInitialState()
            feedFromHost(data)
        }
    }

    func terminalFeed(_ data: Data) {
        feedFromHost(data)
    }

    private func feedFromHost(_ data: Data) {
        feedingHost = true
        defer { feedingHost = false }
        feedPreservingSelection(data)
        allowMouseReporting = !hasActiveSelection
    }

    /// Replies the emulator produces while drawing host output are dropped:
    /// tmux already answered the shell's terminal queries.
    /// A reset or alternate-screen switch replaces the selected document.
    nonisolated override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        Task { @MainActor [weak self] in
            self?.touchInteraction?.cancelScrolling()
            self?.selectNone()
        }
    }

    /// SwiftTerm's default iOS mouse pan sends button press/drag events. A
    /// phone browsing gesture is a wheel instead; clicks keep the native path.
    nonisolated override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        Task { @MainActor [weak self] in self?.touchInteraction?.cancelScrolling() }
    }

    nonisolated override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.allowMouseReporting = !self.selectionActive
        }
    }

    var canSendTouchInput: Bool { presented && allowsInput && stream?.phase == .live }

    /// Use SwiftTerm's negotiated wheel encoding and the existing encrypted
    /// input queue. One frame is one batch, without returning history to live.
    func sendTouchScroll(lines: Int, at point: CGPoint) {
        guard canSendTouchInput, !hasActiveSelection, lines != 0 else { return }
        let emulator = terminalDimensions
        guard (terminalInputStateSnapshot()?.mouseMode ?? .off) != .off else { return }
        let optimal = getOptimalFrameSize()
        let cellWidth = optimal.width / CGFloat(max(1, emulator.cols))
        let cellHeight = optimal.height / CGFloat(max(1, emulator.rows))
        guard cellWidth > 0, cellHeight > 0 else { return }
        let x = max(0, min(bounds.width - 1, point.x - bounds.minX))
        let y = max(0, min(bounds.height - 1, point.y - bounds.minY))
        let col = min(emulator.cols - 1, Int(x / cellWidth))
        let row = min(emulator.rows - 1, Int(y / cellHeight))
        wheelBytes = []
        defer { wheelBytes = nil }
        for _ in 0..<min(abs(lines), 24) {
            sendMouseEvent(button: lines > 0 ? 4 : 5, release: false,
                           col: col, row: row, pixelX: Int(x), pixelY: Int(y))
        }
        if let bytes = wheelBytes, !bytes.isEmpty { stream?.input.send(bytes[...]) }
    }

    /// SwiftTerm 1.99 sends parser replies and tap reports through this one
    /// callback. Replies arise only while host output is parsed, synchronously
    /// on the main thread; tmux already answered them, so they are dropped.
    /// Anything else is the person's tap from SwiftTerm's gesture handlers,
    /// delivered after SwiftTerm releases its terminal lock.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard !feedingHost else { return }
            let bytes = Array(data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.send(source: self, data: bytes[...])
            }
        }
    }

    // MARK: - TerminalViewDelegate

    /// Typing (keyboard, accessory keys, paste) returns to the live screen,
    /// as in iTerm2: SwiftTerm only scrolls when the caret is off screen.
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        guard presented, allowsInput, stream?.phase == .live else { return }
        if wheelBytes != nil {
            wheelBytes?.append(contentsOf: data)
            return
        }
        touchInteraction?.cancelScrolling()
        scroll(toPosition: 1)
        stream?.input.send(data)
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        scheduleFit()
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: SwiftTerm.TerminalView) {}

    /// OSC 52 from shell output never reaches the pasteboard: programs in the
    /// shell may not replace what the person copied (iTerm2's default; security
    /// review 2026-10-07). Selecting and copying text in the terminal still works.
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}

    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }

    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
}
