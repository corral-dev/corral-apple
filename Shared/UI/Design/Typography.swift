import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 字体角色：正文走系统字体，路径 / 按键 / 终端 / 代码块走等宽。
enum Typography {
    static let sessionTitle = Font.headline
    /// List preview sits a full step below the row title so titles lead the row.
    static let sessionPreview = Font.footnote
    static let sessionMeta = Font.caption
    static let sessionPath = Font.caption.monospaced()
    static let sectionHeader = Font.subheadline.weight(.semibold)
    static let bubbleBody = Font.body
    static let toolTitle = Font.subheadline.weight(.semibold)
    static let toolMeta = Font.caption
    static let code = Font.caption.monospaced()
    static let keycap = Font.caption.monospaced().weight(.medium)
    static let status = Font.caption.monospaced()
    static let connection = Font.caption.weight(.medium)

    /// 会话对话内容用：在系统动态字号之上再乘档位缩放。
    static func session(_ style: SessionFontStyle, scale: CGFloat) -> Font {
        Font(sessionUIFont(style, scale: scale))
    }

    /// Platform text host (selectable UITextView / NSTextView) must match SwiftUI bubble metrics.
    static func sessionUIFont(_ style: SessionFontStyle, scale: CGFloat) -> PlatformFont {
        #if os(macOS)
        // macOS has no Dynamic Type; these are the Mac reading sizes (body 13 pt
        // is the system default, conversation text reads one step larger).
        switch style {
        case .bubbleBody:
            return .systemFont(ofSize: 14 * scale)
        case .toolTitle, .sectionHeader:
            return .systemFont(ofSize: 13 * scale, weight: .semibold)
        case .toolMeta:
            return .systemFont(ofSize: 11 * scale)
        case .code:
            return .monospacedSystemFont(ofSize: 11.5 * scale, weight: .regular)
        }
        #else
        switch style {
        case .bubbleBody:
            scaledUIFont(baseSize: 17, textStyle: .body, scale: scale)
        case .toolTitle, .sectionHeader:
            scaledUIFont(baseSize: 15, textStyle: .subheadline, weight: .semibold, scale: scale)
        case .toolMeta:
            scaledUIFont(baseSize: 12, textStyle: .caption1, scale: scale)
        case .code:
            scaledUIFont(baseSize: 12, textStyle: .caption1, monospaced: true, scale: scale)
        }
        #endif
    }

    #if canImport(UIKit)
    private static func scaledUIFont(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        monospaced: Bool = false,
        scale: CGFloat
    ) -> UIFont {
        let size = baseSize * scale
        let base: UIFont
        if monospaced {
            base = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        } else {
            base = UIFont.systemFont(ofSize: size, weight: weight)
        }
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }
    #endif
}
