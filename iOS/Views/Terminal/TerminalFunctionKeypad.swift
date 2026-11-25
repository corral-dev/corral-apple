import SwiftTerm
import UIKit

/// App-specific function and editing keys in UIKit's alternate input surface.
final class TerminalFunctionKeypad: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    private enum Key {
        case symbol(String)
        case insert, home, pageUp, forwardDelete, end, pageDown

        var title: String {
            switch self {
            case .symbol(let text): text
            case .insert: "Ins"
            case .home: "Home"
            case .pageUp: "PgUp"
            case .forwardDelete: ""
            case .end: "End"
            case .pageDown: "PgDn"
            }
        }

        var image: String? {
            guard case .forwardDelete = self else { return nil }
            return "delete.forward"
        }

        var accessibilityName: String {
            switch self {
            case .insert: String(localized: "terminal.keypad.insert")
            case .home: String(localized: "terminal.keypad.home")
            case .pageUp: String(localized: "terminal.keypad.page_up")
            case .forwardDelete: String(localized: "terminal.keypad.forward_delete")
            case .end: String(localized: "terminal.keypad.end")
            case .pageDown: String(localized: "terminal.keypad.page_down")
            default: title
            }
        }

        var identifier: String {
            if case .forwardDelete = self { return "terminal.keypad.forward-delete" }
            return "terminal.keypad.\(title)"
        }

        var font: UIFont {
            if case .symbol = self { return .systemFont(ofSize: 17, weight: .medium) }
            return .systemFont(ofSize: 11, weight: .semibold)
        }

        func send(to terminal: SwiftTerm.TerminalView) {
            switch self {
            case .symbol(let text): terminal.send(txt: text)
            case .insert: terminal.send(EscapeSequences.cmdInsert)
            case .home: terminal.sendKeyHome()
            case .pageUp: terminal.send(EscapeSequences.cmdPageUp)
            case .forwardDelete: terminal.send(EscapeSequences.cmdDelKey)
            case .end: terminal.sendKeyEnd()
            case .pageDown: terminal.send(EscapeSequences.cmdPageDown)
            }
        }
    }

    /// Ten key columns share the keyboard width up to a readable cap.
    static let maxKeyWidth: CGFloat = 52
    static let horizontalInset: CGFloat = 4
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 6

    init(frame: CGRect, terminal: SwiftTerm.TerminalView) {
        super.init(frame: frame, inputViewStyle: .keyboard)
        semanticContentAttribute = .forceLeftToRight

        let edits: [[Key]] = [
            "[]{}<>&".map { .symbol(String($0)) } + [.insert, .home, .pageUp],
            "+-*=%`\\".map { .symbol(String($0)) } + [.forwardDelete, .end, .pageDown]
        ]
        let rows = [TerminalKeyButton.functionKeys(terminal: terminal)]
            + edits.map { $0.map { Self.makeButton(for: $0, terminal: terminal) } }
        let grid = UIStackView(arrangedSubviews: rows.map { buttons in
            let row = UIStackView(arrangedSubviews: buttons)
            row.distribution = .fillEqually
            row.spacing = TerminalShortcutStrip.keySpacing
            return row
        })
        grid.axis = .vertical
        grid.distribution = .fillEqually
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        let fillLeading = grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset)
        let fillTrailing = grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset)
        fillLeading.priority = .defaultHigh
        fillTrailing.priority = .defaultHigh
        let cap = grid.widthAnchor.constraint(lessThanOrEqualToConstant: 10 * Self.maxKeyWidth + 9 * TerminalShortcutStrip.keySpacing)
        NSLayoutConstraint.activate([
            fillLeading, fillTrailing, cap,
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.horizontalInset),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalInset),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset),
            grid.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Self.bottomInset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func makeButton(for key: Key, terminal: SwiftTerm.TerminalView) -> UIButton {
        let button = TerminalKeyButton.make(id: key.identifier, title: key.title, symbol: key.image,
                                            label: key.accessibilityName, font: key.font)
        TerminalKeyButton.onActivate(button) { [weak terminal] in
            guard let terminal else { return }
            key.send(to: terminal)
        }
        return button
    }
}
