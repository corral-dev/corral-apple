import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm's UIKit terminal fed by a host shell or agent stream. The view's own grid
/// (its frame at the phone font) is the size it votes; the host makes the
/// latest active viewer's grid the shell's, so typing here sizes the shell to
/// the phone. The terminal input accessory supplies Esc, Ctrl, Tab and arrows.
struct ShellTerminalView: UIViewRepresentable {
    let stream: RemoteTerminalStream
    var isPresented = true
    var allowsInput = true
    var isAgent = false
    var usesIdentityBackground = false
    var fontSize: CGFloat = ShellTerminalHost.fontSize
    var onFontSizeChange: ((Double) -> Void)? = nil
    var onBackgroundColorChange: ((TerminalRGB) -> Void)? = nil

    func makeUIView(context: Context) -> ShellTerminalHost {
        let view = ShellTerminalHost(frame: .zero, fontSize: fontSize)
        view.configure(presented: isPresented, allowsInput: allowsInput, isAgent: isAgent,
                       usesIdentityBackground: usesIdentityBackground,
                       fontSize: fontSize,
                       onFontSizeChange: onFontSizeChange,
                       onBackgroundColorChange: onBackgroundColorChange)
        view.bind(stream)
        return view
    }

    func updateUIView(_ view: ShellTerminalHost, context: Context) {
        view.configure(presented: isPresented, allowsInput: allowsInput, isAgent: isAgent,
                       usesIdentityBackground: usesIdentityBackground,
                       fontSize: fontSize,
                       onFontSizeChange: onFontSizeChange,
                       onBackgroundColorChange: onBackgroundColorChange)
        if view.stream !== stream { view.bind(stream) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShellTerminalHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 400)
    }

    static func dismantleUIView(_ view: ShellTerminalHost, coordinator: ()) {
        view.unbind()
    }
}

/// Adopts a long-lived `ShellTerminalHost` owned by `MobileTerminalSessions` into
/// this detail's UIKit hierarchy so Back navigation and session switches keep the
/// emulator and host stream intact instead of reconnecting.
struct RetainedShellTerminalView: UIViewRepresentable {
    let host: ShellTerminalHost
    var isPresented = true
    var sceneActive = true
    var allowsInput = true
    var isAgent = true
    var usesIdentityBackground = false
    var fontSize: CGFloat = ShellTerminalHost.fontSize
    var onFontSizeChange: ((Double) -> Void)? = nil
    var onBackgroundColorChange: ((TerminalRGB) -> Void)? = nil

    func makeUIView(context: Context) -> ShellTerminalSlot {
        let slot = ShellTerminalSlot()
        update(slot)
        return slot
    }

    func updateUIView(_ slot: ShellTerminalSlot, context: Context) {
        update(slot)
    }

    private func update(_ slot: ShellTerminalSlot) {
        if host.superview !== slot {
            guard isPresented else { return }
            slot.adopt(host)
        }
        host.configure(
            presented: isPresented,
            sceneActive: sceneActive,
            allowsInput: allowsInput,
            isAgent: isAgent,
            usesIdentityBackground: usesIdentityBackground,
            fontSize: fontSize,
            onFontSizeChange: onFontSizeChange,
            onBackgroundColorChange: onBackgroundColorChange
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShellTerminalSlot, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 400)
    }

    static func dismantleUIView(_ slot: ShellTerminalSlot, coordinator: ()) {
        slot.release()
    }
}

/// UIKit container slot lending a frame to a retained `ShellTerminalHost`.
final class ShellTerminalSlot: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for case let host as ShellTerminalHost in subviews where host.frame != bounds {
            host.frame = bounds
        }
    }

    func adopt(_ host: ShellTerminalHost) {
        host.removeFromSuperview()
        host.frame = bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host)
        host.setNeedsLayout()
    }

    func release() {
        for case let host as ShellTerminalHost in subviews {
            host.setPresented(false)
            host.removeFromSuperview()
        }
    }
}

final class ShellTerminalHost: SwiftTerm.TerminalView, TerminalStreamSink, TerminalViewDelegate {
    static let fontSize: CGFloat = CGFloat(MobileZoomPreferences.terminalDefaultFontSize)

    private(set) weak var stream: RemoteTerminalStream?
    private(set) var currentFontSize: CGFloat
    private var feedingHost = false
    private var presented = true
    private var sceneActive = true
    private var allowsInput = true
    private var isAgent = false
    private var usesIdentityBackground = false
    private var scheme = TerminalColorScheme.dark
    private var touchInteraction: TerminalTouchInteraction?
    private var wheelBytes: [UInt8]?
    private var isPinching = false
    private var pinchStartFontSize: CGFloat?
    private var pendingFontHostReconcile = false
    private var onFontSizeChange: ((Double) -> Void)?
    private var onBackgroundColorChange: ((TerminalRGB) -> Void)?
    private var lastReportedBackground: TerminalRGB?
    private var backgroundSamplePending = false

    var hasScreen: Bool { hostGrid != nil }
    var isShown: Bool { window != nil && presented && !isHidden }
    var isInFront: Bool { presented && sceneActive }
    var canPinchZoom: Bool { presented && !isHidden }
    var currentBackgroundRGB: TerminalRGB? { lastReportedBackground }

    init(frame: CGRect, fontSize: CGFloat) {
        let clamped = CGFloat(MobileZoomPreferences.clampTerminalFontSize(Double(fontSize)))
        self.currentFontSize = clamped
        super.init(frame: frame, font: UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular))
        terminalDelegate = self
        inputAccessoryView = TerminalShortcutStrip(terminal: self)
        changeScrollback(10_000)
        touchInteraction = TerminalTouchInteraction(terminal: self)
        applyScheme()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShellTerminalHost, _: UITraitCollection) in
            view.applyScheme()
        }
    }

    override convenience init(frame: CGRect) {
        self.init(frame: frame, fontSize: Self.fontSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func bind(_ stream: RemoteTerminalStream) {
        self.stream?.sink = nil
        self.stream = stream
        stream.sink = self
        stream.isInFront = { [weak self] in self?.isInFront ?? false }
        stream.updateTheme(scheme.theme)
        lastReportedFit = nil
        if !hasScreen {
            lastReportedBackground = nil
        }
        scheduleFit()
        scheduleSurfaceBackgroundSample(immediate: true)
    }

    func terminalRevealPrompt(_ query: String) -> Bool { revealPrompt(query) }
    func terminalRevealPrompt(_ query: String, occurrence: Int, total: Int) -> Bool {
        revealPrompt(query, occurrence: occurrence, total: total)
    }

    func unbind() {
        touchInteraction?.reset()
        cancelPendingFit()
        cancelPendingSurfaceBackgroundSample()
        lastReportedFit = nil
        lastReportedBackground = nil
        isPinching = false
        pinchStartFontSize = nil
        pendingFontHostReconcile = false
        onFontSizeChange = nil
        onBackgroundColorChange = nil
        stream?.isInFront = { false }
        stream?.sink = nil
        stream = nil
    }

    func setPresented(_ presented: Bool) {
        self.presented = presented
        isHidden = !presented
        accessibilityElementsHidden = !presented
        if !presented {
            if isFirstResponder { _ = resignFirstResponder() }
            touchInteraction?.reset()
            cancelPendingFit()
            cancelPendingSurfaceBackgroundSample()
        }
    }

    func configure(presented: Bool, sceneActive: Bool = true, allowsInput: Bool, isAgent: Bool,
                   usesIdentityBackground: Bool = false,
                   fontSize: CGFloat = ShellTerminalHost.fontSize,
                   onFontSizeChange: ((Double) -> Void)? = nil,
                   onBackgroundColorChange: ((TerminalRGB) -> Void)? = nil) {
        self.onFontSizeChange = onFontSizeChange
        self.onBackgroundColorChange = onBackgroundColorChange
        if self.usesIdentityBackground != usesIdentityBackground {
            self.usesIdentityBackground = usesIdentityBackground
            applyScheme()
        }
        let wasInFront = isInFront
        let revealed = !self.presented && presented
        self.sceneActive = sceneActive
        self.allowsInput = allowsInput
        self.isAgent = isAgent
        setPresented(presented)
        if !allowsInput && isFirstResponder { _ = resignFirstResponder() }

        let targetFontSize = CGFloat(MobileZoomPreferences.clampTerminalFontSize(Double(fontSize)))
        var didChangeFont = false
        if !isPinching, presented, abs(targetFontSize - currentFontSize) >= 0.25 {
            currentFontSize = targetFontSize
            self.font = UIFont.monospacedSystemFont(ofSize: targetFontSize, weight: .regular)
            didChangeFont = true
            if bounds.width > 0, bounds.height > 0 {
                reconcileHostAfterFontChange()
            } else {
                pendingFontHostReconcile = true
            }
        }

        if revealed {
            setNeedsDisplay()
            if hasScreen && isInFront && (stream?.phase == .live || stream?.needsRevealRecover == true) {
                stream?.claimSize()
            }
            if !didChangeFont || pendingFontHostReconcile {
                scheduleFit()
            }
            if let cachedBg = lastReportedBackground {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.presented else { return }
                    self.onBackgroundColorChange?(cachedBg)
                }
            }
            scheduleSurfaceBackgroundSample(immediate: true)
        } else if !wasInFront && isInFront && hasScreen && (stream?.phase == .live || stream?.needsRevealRecover == true) {
            stream?.claimSize()
        } else if presented && lastReportedBackground == nil {
            scheduleSurfaceBackgroundSample(immediate: true)
        }
    }

    func beginPinchZoom() {
        guard canPinchZoom else { return }
        isPinching = true
        pinchStartFontSize = currentFontSize
        cancelPendingFit()
    }

    func updatePinchZoom(scale: CGFloat) {
        guard isPinching, let start = pinchStartFontSize else { return }
        let next = CGFloat(MobileZoomPreferences.scaledTerminalFontSize(
            from: Double(start),
            magnification: Double(scale)
        ))
        guard next != currentFontSize else { return }
        currentFontSize = next
        self.font = UIFont.monospacedSystemFont(ofSize: next, weight: .regular)
        scheduleSurfaceBackgroundSample(immediate: false)
    }

    func endPinchZoom(scale: CGFloat, cancelled: Bool) {
        guard isPinching, let start = pinchStartFontSize else { return }
        if !cancelled {
            let final = CGFloat(MobileZoomPreferences.scaledTerminalFontSize(
                from: Double(start),
                magnification: Double(scale)
            ))
            if final != currentFontSize {
                currentFontSize = final
                self.font = UIFont.monospacedSystemFont(ofSize: final, weight: .regular)
            }
        }
        isPinching = false
        pinchStartFontSize = nil
        let changed = currentFontSize != start
        if !cancelled || changed {
            onFontSizeChange?(Double(currentFontSize))
        }
        if changed {
            reconcileHostAfterFontChange()
        } else {
            scheduleFit()
        }
    }

    func cancelPinchZoomIfNeeded() {
        guard isPinching else { return }
        endPinchZoom(scale: 1, cancelled: true)
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
        if window != nil, presented {
            setNeedsDisplay()
            scheduleFit()
        }
    }

    private func applyScheme() {
        let next: TerminalColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let changed = next.background != scheme.background
        scheme = next
        nativeBackgroundColor = Self.color(next.background)
        backgroundOpacity = usesIdentityBackground ? 0 : 1
        nativeForegroundColor = Self.color(next.foreground)
        installColors(next.ansi.map { SwiftTerm.Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue)) })
        keyboardAppearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        if changed { stream?.updateTheme(next.theme) }
        scheduleSurfaceBackgroundSample(immediate: true)
    }

    private func scheduleSurfaceBackgroundSample(immediate: Bool) {
        guard presented else { return }
        if immediate {
            cancelPendingSurfaceBackgroundSample()
            DispatchQueue.main.async { [weak self] in
                self?.sampleSurfaceBackground()
            }
            return
        }
        guard !backgroundSamplePending else { return }
        backgroundSamplePending = true
        perform(#selector(sampleSurfaceBackground), with: nil, afterDelay: 0.18)
    }

    private func cancelPendingSurfaceBackgroundSample() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(sampleSurfaceBackground), object: nil)
        backgroundSamplePending = false
    }

    @objc private func sampleSurfaceBackground() {
        backgroundSamplePending = false
        guard presented else { return }
        let resolved: TerminalRGB
        if let snapshot = terminalContentSnapshot(region: .viewport) {
            let defaultBg = snapshot.backgroundColor.map {
                TerminalRGB(red16: $0.red, green16: $0.green, blue16: $0.blue)
            } ?? scheme.backgroundRGB
            let defaultFg = snapshot.foregroundColor.map {
                TerminalRGB(red16: $0.red, green16: $0.green, blue16: $0.blue)
            } ?? scheme.foregroundRGB
            let palette = snapshot.palette.map {
                TerminalRGB(red16: $0.red, green16: $0.green, blue16: $0.blue)
            }
            let rows = snapshot.rows.map { row in
                row.cells.map { cell in
                    TerminalSurfaceBackgroundResolver.CellSample(
                        width: cell.width,
                        foreground: Self.cellColor(cell.attribute.fg),
                        background: Self.cellColor(cell.attribute.bg),
                        isInverse: cell.attribute.style.contains(.inverse)
                    )
                }
            }
            resolved = TerminalSurfaceBackgroundResolver.resolve(
                rows: rows,
                columns: snapshot.dimensions.cols,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            )
        } else {
            resolved = scheme.backgroundRGB
        }
        guard resolved != lastReportedBackground else { return }
        lastReportedBackground = resolved
        onBackgroundColorChange?(resolved)
    }

    private static func cellColor(_ color: Attribute.Color) -> TerminalSurfaceBackgroundResolver.CellColor {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            .defaultColor
        case .ansi256(let code):
            .ansi256(code)
        case .trueColor(let red, let green, let blue):
            .trueColor(TerminalRGB(red: red, green: green, blue: blue))
        }
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
        guard presented, !feedingHost, !isPinching, bounds.width > 0, bounds.height > 0 else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(deliverFit), object: nil)
        // Schedule across `.common` modes so navigation/scroll tracking never starves cold-open fit delivery.
        perform(#selector(deliverFit), with: nil, afterDelay: 0.15, inModes: [.common])
    }

    private func cancelPendingFit() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(deliverFit), object: nil)
    }

    private func computeFit() -> TerminalGrid? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let emulator = terminalDimensions
        let optimal = getOptimalFrameSize()
        let cellWidth = optimal.width / CGFloat(max(1, emulator.cols))
        let cellHeight = optimal.height / CGFloat(max(1, emulator.rows))
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        // Fit derives from the local viewport, never a received desktop grid.
        return TerminalGrid(
            cols: max(isAgent ? 40 : 20, Int(bounds.width / cellWidth)),
            rows: max(isAgent ? 10 : 5, Int(bounds.height / cellHeight))
        )
    }

    /// Reconciles the host after SwiftTerm's `font` setter runs `resetFont()` ->
    /// `softReset()`, either voting the new grid or requesting a fresh snapshot
    /// when the grid stayed unchanged (e.g., at the column floor or read-only).
    private func reconcileHostAfterFontChange() {
        guard presented, !feedingHost else { return }
        cancelPendingFit()
        scheduleSurfaceBackgroundSample(immediate: true)
        guard let fit = computeFit() else {
            pendingFontHostReconcile = true
            scheduleFit()
            return
        }
        pendingFontHostReconcile = false
        if allowsInput, fit != lastReportedFit {
            lastReportedFit = fit
            stream?.updateFit(fit)
        } else if hasScreen, stream?.phase == .live {
            stream?.refreshSnapshot()
        }
    }

    @objc private func deliverFit() {
        guard presented, !feedingHost, !isPinching, bounds.width > 0, bounds.height > 0 else { return }
        if pendingFontHostReconcile {
            reconcileHostAfterFontChange()
            return
        }
        guard let fit = computeFit(), fit != lastReportedFit else { return }
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
        scheduleSurfaceBackgroundSample(immediate: true)
    }

    func terminalFeed(_ data: Data) {
        feedFromHost(data)
        scheduleSurfaceBackgroundSample(immediate: false)
    }

    private func feedFromHost(_ data: Data) {
        feedingHost = true
        defer { feedingHost = false }
        feedPreservingSelection(data)
        updateMouseReportingForSelection(!hasActiveSelection)
    }

    private func updateMouseReportingForSelection(_ enabled: Bool) {
        guard allowMouseReporting != enabled else { return }
        allowMouseReporting = enabled
        (inputAccessoryView as? TerminalShortcutStrip)?.refreshState()
    }

    /// Replies the emulator produces while drawing host output are dropped:
    /// tmux already answered the shell's terminal queries.
    /// A reset or alternate-screen switch replaces the selected document.
    nonisolated override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        Task { @MainActor [weak self] in
            self?.touchInteraction?.cancelScrolling()
            self?.selectNone()
            self?.scheduleSurfaceBackgroundSample(immediate: true)
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
            self.updateMouseReportingForSelection(!self.selectionActive)
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
        guard !isPinching else { return }
        scheduleFit()
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {
        scheduleSurfaceBackgroundSample(immediate: false)
    }

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
