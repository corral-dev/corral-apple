import SwiftUI

/// 会话对话内容的字号档位。默认「标准」跟随系统正文，其它档位是相对缩放。
enum SessionTextSize: String, CaseIterable, Identifiable, Sendable {
    case extraSmall
    case small
    case medium
    case large
    case extraLarge

    static let storageKey = "corral.sessionTextSize"
    static let `default` = SessionTextSize.medium

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .extraSmall: 0.85
        case .small: 0.92
        case .medium: 1.0
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .extraSmall: "settings.session_text_size.extra_small"
        case .small: "settings.session_text_size.small"
        case .medium: "settings.session_text_size.medium"
        case .large: "settings.session_text_size.large"
        case .extraLarge: "settings.session_text_size.extra_large"
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 2)
    }

    static func resolve(stored: String?) -> SessionTextSize {
        stored.flatMap(SessionTextSize.init(rawValue:)) ?? .default
    }

    static func from(sliderIndex: Double) -> SessionTextSize {
        let clamped = min(max(Int(sliderIndex.rounded()), 0), allCases.count - 1)
        return allCases[clamped]
    }
}

enum SessionFontStyle {
    case bubbleBody
    case toolTitle
    case toolMeta
    case code
    case sectionHeader
}

private struct SessionTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = SessionTextSize.default.scale
}

extension EnvironmentValues {
    var sessionTextScale: CGFloat {
        get { self[SessionTextScaleKey.self] }
        set { self[SessionTextScaleKey.self] = newValue }
    }
}

extension View {
    func sessionFont(_ style: SessionFontStyle) -> some View {
        modifier(SessionFontModifier(style: style))
    }
}

private struct SessionFontModifier: ViewModifier {
    @Environment(\.sessionTextScale) private var scale
    @Environment(\.interfaceScale) private var interfaceScale
    let style: SessionFontStyle

    func body(content: Content) -> some View {
        content.font(Typography.session(style, scale: scale * interfaceScale))
    }
}
