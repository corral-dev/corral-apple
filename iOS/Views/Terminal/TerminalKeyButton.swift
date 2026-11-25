import SwiftTerm
import UIKit

/// Shared UIKit keycap styling for the terminal accessory and function keypad.
/// Every key gets the same visible cap; only the label treatment differs.
enum TerminalKeyButton {
    static let fill: UIColor = .secondarySystemFill
    static let backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 1, bottom: 4, trailing: 1)

    static func make(id: String, title: String? = nil, symbol: String? = nil,
                     label: String? = nil, font: UIFont = .systemFont(ofSize: 12, weight: .semibold)) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .medium
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = fill
        configuration.background.backgroundInsets = backgroundInsets
        configuration.contentInsets = .zero
        configuration.title = title
        configuration.titleLineBreakMode = .byClipping
        if let symbol {
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }

        let button = UIButton(configuration: configuration)
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.accessibilityTraits.insert(.keyboardKey)
        button.accessibilityLabel = label ?? title
        button.accessibilityIdentifier = id
        button.configurationUpdateHandler = { button in
            button.configuration?.baseBackgroundColor = button.isSelected ? button.tintColor.withAlphaComponent(0.20) : fill
        }
        return button
    }

    static func onActivate(_ button: UIButton, _ action: @escaping () -> Void) {
        button.addAction(UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        }, for: .primaryActionTriggered)
    }

    static func functionKeys(terminal: TerminalView) -> [UIButton] {
        EscapeSequences.cmdF.prefix(10).enumerated().map { index, sequence in
            let title = "F\(index + 1)"
            let button = make(id: "terminal.keypad.\(title)", title: title,
                              font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
            onActivate(button) { [weak terminal] in terminal?.send(sequence) }
            return button
        }
    }
}
