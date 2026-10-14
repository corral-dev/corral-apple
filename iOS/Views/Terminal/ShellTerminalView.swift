import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm's UIKit terminal fed by a host shell stream. The view's own grid
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

    override init(frame: CGRect) {
        super.init(frame: frame, font: UIFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular))
        terminalDelegate = self
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
        reportFit()
    }

    func unbind() {
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
        if revealed { reportFit() }
    }

    override var canBecomeFirstResponder: Bool { presented && allowsInput && super.canBecomeFirstResponder }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportFit()
    }

    override func paste(_ sender: Any?) {
        guard presented, allowsInput, stream?.phase == .live, let text = UIPasteboard.general.string else { return }
        scroll(toPosition: 1)
        stream?.input.paste(text)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The terminal is the screen's only input: the keyboard comes up with it.
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

    private func reportFit() {
        guard presented, !feedingHost, bounds.width > 0, bounds.height > 0 else { return }
        let emulator = getTerminal()
        let optimal = getOptimalFrameSize()
        let cellWidth = optimal.width / CGFloat(max(1, emulator.cols))
        let cellHeight = optimal.height / CGFloat(max(1, emulator.rows))
        guard cellWidth > 0, cellHeight > 0 else { return }
        // Fit derives from the local viewport, never a received desktop grid.
        stream?.updateFit(TerminalGrid(
            cols: max(isAgent ? 40 : 20, Int(bounds.width / cellWidth)),
            rows: max(isAgent ? 10 : 5, Int(bounds.height / cellHeight))
        ))
    }

    // MARK: - TerminalStreamSink

    func terminalReset(grid: TerminalGrid, data: Data) {
        feedingHost = true
        defer { feedingHost = false }
        let emulator = getTerminal()
        if emulator.cols != grid.cols || emulator.rows != grid.rows {
            resize(cols: grid.cols, rows: grid.rows)
        }
        emulator.resetToInitialState()
        feedFromHost(data)
    }

    func terminalFeed(_ data: Data) {
        feedFromHost(data)
    }

    private func feedFromHost(_ data: Data) {
        feedingHost = true
        defer { feedingHost = false }
        feedPreservingSelection(data)
    }

    /// Replies the emulator produces while drawing host output are dropped:
    /// tmux already answered the shell's terminal queries.
    /// A reset or alternate-screen switch replaces the selected document.
    override func bufferActivated(source: Terminal) {
        selection?.selectNone()
        super.bufferActivated(source: source)
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !feedingHost, presented, allowsInput, stream?.phase == .live else { return }
        super.send(source: source, data: data)
    }

    // MARK: - TerminalViewDelegate

    /// Typing (keyboard, accessory keys, paste) returns to the live screen,
    /// as in iTerm2: SwiftTerm only scrolls when the caret is off screen.
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        guard presented, allowsInput, stream?.phase == .live else { return }
        scroll(toPosition: 1)
        stream?.input.send(data)
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        reportFit()
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
