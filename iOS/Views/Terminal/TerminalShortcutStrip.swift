import SwiftTerm
import UIKit

/// Corral's terminal-only input accessory. UIKit still owns text input and
/// presentation; SwiftTerm still encodes and delivers the terminal keys.
final class TerminalShortcutStrip: UIInputView, UIInputViewAudioFeedback {
    private static let scope = "terminal.shortcut"
    /// Keys share the width up to this cap, so a wide keyboard never turns
    /// into oversized touch targets.
    static let maxKeyWidth: CGFloat = 56
    static let keySpacing: CGFloat = 2
    static let horizontalInset: CGFloat = 4
    private let row = UIStackView()
    private let rowHeight: CGFloat
    private weak var terminal: TerminalView?
    private var modifiers: [Key: UIButton] = [:]
    private var widthCap: NSLayoutConstraint?
    private var repeating: Task<Void, Never>?

    var enableInputClicksWhenVisible: Bool { true }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: rowHeight) }

    private enum Key: String {
        case escape, control, tab, tilde, slash, left, down, up, right, touch, keyboard

        var title: String? {
            switch self {
            case .escape: "Esc"
            case .control: "Ctrl"
            case .tilde: "~"
            case .slash: "/"
            default: nil
            }
        }

        var symbol: String? {
            switch self {
            case .tab: return "arrow.right.to.line.compact"
            case .left: return "arrow.left"
            case .down: return "arrow.down"
            case .up: return "arrow.up"
            case .right: return "arrow.right"
            case .touch: return "hand.draw"
            case .keyboard: return "keyboard.chevron.compact.down"
            default: return nil
            }
        }

        var label: String? {
            switch self {
            case .escape: String(localized: "terminal.keypad.escape")
            case .control: String(localized: "terminal.keypad.control")
            case .tab: String(localized: "terminal.keypad.tab")
            case .left: String(localized: "terminal.keypad.arrow_left")
            case .down: String(localized: "terminal.keypad.arrow_down")
            case .up: String(localized: "terminal.keypad.arrow_up")
            case .right: String(localized: "terminal.keypad.arrow_right")
            case .touch: String(localized: "terminal.keypad.local_touch")
            default: title
            }
        }

        var isArrow: Bool {
            switch self {
            case .left, .down, .up, .right: true
            default: false
            }
        }
    }

    init(terminal: TerminalView) {
        self.terminal = terminal
        rowHeight = terminal.traitCollection.userInterfaceIdiom == .pad ? 48 : 36
        super.init(frame: CGRect(x: 0, y: 0, width: terminal.bounds.width, height: rowHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        semanticContentAttribute = .forceLeftToRight
        buildRow(terminal: terminal)
        refreshState()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshState),
                                               name: .terminalViewControlModifierReset, object: terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildRow(terminal: TerminalView) {
        let keys: [Key] = [.escape, .control, .tab, .tilde, .slash, .left, .down, .up, .right, .touch, .keyboard]
        keys.map(makeButton).forEach(row.addArrangedSubview)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Self.keySpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let cap = row.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxKeyWidth)
        widthCap = cap
        // Prefer the full keyboard width, then give way to the key-width cap on wide keyboards.
        let fillLeading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset)
        let fillTrailing = row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset)
        fillLeading.priority = .defaultHigh
        fillTrailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fillLeading, fillTrailing, cap,
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.horizontalInset),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalInset),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateWidthCap()
    }

    override func layoutSubviews() {
        updateWidthCap()
        super.layoutSubviews()
    }

    private func updateWidthCap() {
        let count = CGFloat(row.arrangedSubviews.count)
        guard count > 0 else { return }
        let cap = count * Self.maxKeyWidth + (count - 1) * Self.keySpacing
        if abs((widthCap?.constant ?? 0) - cap) > 0.5 { widthCap?.constant = cap }
    }

    private func makeButton(_ key: Key) -> UIButton {
        let button = TerminalKeyButton.make(id: "\(Self.scope).\(key.rawValue)", title: key.title, symbol: key.symbol,
                                            label: key.label)
        TerminalKeyButton.onActivate(button) { [weak self] in self?.perform(key) }
        switch key {
        case .control, .touch, .keyboard: modifiers[key] = button
        default: break
        }
        if key.isArrow {
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdArrow(_:)))
            hold.minimumPressDuration = 0.6
            button.addGestureRecognizer(hold)
        }
        return button
    }

    @objc func refreshState() {
        guard let terminal else { return }
        modifiers[.control]?.isSelected = terminal.controlModifier
        modifiers[.touch]?.isSelected = !terminal.allowMouseReporting
        let showingFunctionKeys = terminal.inputView != nil
        modifiers[.keyboard]?.isSelected = showingFunctionKeys
        modifiers[.keyboard]?.accessibilityLabel = showingFunctionKeys
            ? String(localized: "terminal.keypad.show_system")
            : String(localized: "terminal.keypad.show_functions")
    }

    private func perform(_ key: Key) {
        guard let terminal else { return }
        switch key {
        case .escape: terminal.send([0x1b])
        case .tab: terminal.send([0x09])
        case .left: terminal.sendKeyLeft()
        case .down: terminal.sendKeyDown()
        case .up: terminal.sendKeyUp()
        case .right: terminal.sendKeyRight()
        case .tilde, .slash:
            if let text = key.title { insertShortcut(text, in: terminal) }
        case .control:
            terminal.controlModifier.toggle()
            refreshState()
        case .touch:
            terminal.allowMouseReporting.toggle()
            refreshState()
        case .keyboard:
            toggleKeypad(for: terminal)
        }
    }

    private func insertShortcut(_ text: String, in terminal: TerminalView) {
        // Accessory symbols are literal even with the one-shot modifier armed.
        // Use SwiftTerm's text path so composition and Kitty encoding still work.
        let control = terminal.controlModifier
        let meta = terminal.metaModifier
        terminal.controlModifier = false
        terminal.metaModifier = false
        terminal.insertText(text)
        terminal.controlModifier = control
        terminal.metaModifier = meta
        refreshState()
    }

    private func toggleKeypad(for terminal: TerminalView) {
        if terminal.inputView != nil {
            terminal.inputView = nil
        } else {
            let viewport = terminal.window?.bounds ?? terminal.bounds
            let frame = CGRect(x: 0, y: 0, width: max(bounds.width, viewport.width), height: max(viewport.height / 5, 140))
            terminal.inputView = TerminalFunctionKeypad(frame: frame, terminal: terminal)
        }
        refreshState()
        UIView.performWithoutAnimation { terminal.reloadInputViews() }
    }

    @objc private func holdArrow(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? UIButton else { return }
        switch recognizer.state {
        case .began:
            cancelRepeat()
            button.isHighlighted = true
            button.sendActions(for: .primaryActionTriggered)
            repeating = Task { [weak self, weak button] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    guard let button, button.window != nil, self.terminal?.isFirstResponder == true else {
                        self.cancelRepeat()
                        return
                    }
                    button.sendActions(for: .primaryActionTriggered)
                }
            }
        case .changed:
            if !button.bounds.contains(recognizer.location(in: button)) { cancelRepeat() }
        case .ended, .cancelled, .failed:
            cancelRepeat()
        default: break
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelRepeat() }
        else { refreshState() }
    }

    private func cancelRepeat() {
        repeating?.cancel()
        repeating = nil
        row.arrangedSubviews.compactMap { $0 as? UIButton }.forEach { $0.isHighlighted = false }
    }
}
