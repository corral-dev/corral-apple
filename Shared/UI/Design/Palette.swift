import SwiftUI

/// 品牌与语义色。
///
/// 助手配色与状态色以电脑端 CLI 为唯一来源：
/// - 助手：`cli/src/corral/theme.py` → `RUNTIME_LABEL_STYLES`
/// - 状态：`cli/src/corral/ui/session_list.py` → waiting=黄 / working=绿 / unread=红
enum Palette {
    /// Pine-inspired green, lifted on dark surfaces for readable interaction.
    static let accent = Color("AccentColor")
    /// Saturated project ink stays distinct from neutral titles in both appearances.
    /// Native gray selection needs its own foreground contrast pair.
    static func sessionProject(selected: Bool = false) -> Color {
        Color(selected ? "ProjectTextSelected" : "ProjectText")
    }
    /// Contrasting content on a filled primary action.
    static let onAccent = Color("OnAccentColor")
    /// Warm yellow sampled from the app-icon hat.
    static let brandYellow = Color(hex: 0xFDC553)
    /// Deep pine for brand tiles such as the machine icon.
    static let brandPine = Color("BrandPine")
    /// Error text, icons and tinted error bands; readable in both appearances.
    /// Status dots keep the CLI attention colors instead.
    static let danger = Color("Danger")
    /// Filled error capsule that always carries white text.
    static let dangerFill = Color(hex: 0xB3261E)
    /// A quiet warm note for auxiliary icon/number surfaces, not message fills.
    static let warmSurface = Color("WarmSurface")

    // MARK: - 助手配色（电脑端同源）

    static let claude = Color(hex: 0xD97757)
    static let codex = Color(hex: 0x60A5FA)
    static let cursor = Color(hex: 0xA78BFA)
    static let kimi = Color(hex: 0xF472B6)
    static let opencode = Color(hex: 0x34D399)
    static let pi = Color(hex: 0xFBBF24)

    /// 未知助手回退色。
    static let runtimeFallback = Color.secondary

    static func runtime(_ id: String?) -> Color {
        switch (id ?? "").lowercased() {
        case "claude": claude
        case "codex": codex
        case "cursor": cursor
        case "kimi": kimi
        case "opencode": opencode
        case "pi": pi
        default: runtimeFallback
        }
    }

    /// Asset Catalog 中的官方标识名；没有官方图形时返回 nil，界面回退系统符号。
    static func runtimeLogoName(_ id: String?) -> String? {
        switch (id ?? "").lowercased() {
        case "claude": "RuntimeClaude"
        case "codex": "RuntimeCodex"
        case "cursor": "RuntimeCursor"
        case "kimi": "RuntimeKimi"
        case "opencode": "RuntimeOpenCode"
        case "pi": "RuntimePi"
        default: nil
        }
    }

    /// 仅未知助手使用。已知助手必须走 `runtimeLogoName` 的官方图形。
    static func runtimeSymbol(_ id: String?) -> String {
        switch (id ?? "").lowercased() {
        case "claude": "sparkles"
        case "codex": "terminal.fill"
        case "cursor": "cursorarrow"
        case "kimi": "bubble.left.and.bubble.right"
        case "opencode": "chevron.left.forwardslash.chevron.right"
        case "pi": "circle.grid.cross"
        default: "terminal.fill"
        }
    }

    /// 顶栏 / 列表用的助手显示名。专有名词，不走本地化。
    static func runtimeDisplayName(_ id: String?) -> String {
        let raw = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "kimi": return "Kimi"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "": return ""
        default: return raw
        }
    }

    // MARK: - 关注状态（电脑端同源）

    /// 等你回复 — CLI `bold yellow`
    static let attentionWaiting = Color(hex: 0xEAB308)
    /// 运行中 — CLI `bold green`
    static let attentionWorking = Color(hex: 0x22C55E)
    /// 有新结果 — CLI `bold red`
    static let attentionUnread = Color(hex: 0xEF4444)

    static func attention(_ kind: AttentionKind) -> Color {
        switch kind {
        case .waiting: attentionWaiting
        case .working: attentionWorking
        case .unread: attentionUnread
        case .none: .clear
        }
    }

    // MARK: - 气泡与表面

    /// Quiet green message surfaces with neutral, appearance-matched text.
    static let userBubble = Color("UserBubble")
    static let userBubbleForeground = Color("UserBubbleForeground")
    /// Assistant / card fill on `systemGroupedBackground` pages.
    /// Must use the *Grouped* secondary token: plain `secondarySystemBackground`
    /// matches the grouped page gray in light mode, so bubbles vanish (dark mode
    /// still contrasts). White-on-gray in light; elevated dark in dark.
    static let assistantBubble = Color(.secondarySystemGroupedBackground)
    static let codeSurface = Color(.tertiarySystemFill)
    static let terminalBackground = Color(red: 0.08, green: 0.09, blue: 0.12)
}

extension Color {
    /// 从 0xRRGGBB 构造，不带 alpha。
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
