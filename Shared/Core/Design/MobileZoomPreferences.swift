import Foundation

/// Cross-session mobile zoom preferences persisted independently for Chat View
/// (scale multiplier) and TUI mode (terminal font size in points).
nonisolated enum MobileZoomPreferences {
    static let chatStorageKey = "corral.ios.chatZoomScale"
    static let terminalStorageKey = "corral.ios.terminalFontSize"

    static let chatDefaultScale: Double = 1.0
    static let chatMinScale: Double = 0.70
    static let chatMaxScale: Double = 2.00
    static let chatLiveStep: Double = 0.03

    static let terminalDefaultFontSize: Double = 11.0
    static let terminalMinFontSize: Double = 7.0
    static let terminalMaxFontSize: Double = 24.0
    static let terminalFontStep: Double = 0.5

    static func clampChatScale(_ value: Double) -> Double {
        guard value.isFinite else { return chatDefaultScale }
        let bounded = min(max(value, chatMinScale), chatMaxScale)
        return (bounded * 100).rounded() / 100
    }

    static func scaledChatScale(from start: Double, magnification: Double) -> Double {
        let base = clampChatScale(start)
        guard magnification.isFinite, magnification > 0 else { return base }
        return clampChatScale(base * magnification)
    }

    /// Quantizes in-flight Chat pinch reflows so fast pinches stay smooth inside
    /// `ScrollView` / `SelectableAttributedText` while always reaching exact clamp ends.
    static func shouldApplyLiveChatScale(_ candidate: Double, current: Double) -> Bool {
        guard candidate != current else { return false }
        return abs(candidate - current) >= chatLiveStep
            || candidate == chatMinScale
            || candidate == chatMaxScale
    }

    static func clampTerminalFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return terminalDefaultFontSize }
        let bounded = min(max(value, terminalMinFontSize), terminalMaxFontSize)
        return (bounded / terminalFontStep).rounded() * terminalFontStep
    }

    static func scaledTerminalFontSize(from start: Double, magnification: Double) -> Double {
        let base = clampTerminalFontSize(start)
        guard magnification.isFinite, magnification > 0 else { return base }
        return clampTerminalFontSize(base * magnification)
    }

    static func loadChatScale(
        defaults: UserDefaults = .standard,
        fallbackScale: Double = chatDefaultScale
    ) -> Double {
        if defaults.object(forKey: chatStorageKey) != nil {
            return clampChatScale(defaults.double(forKey: chatStorageKey))
        }
        return clampChatScale(fallbackScale)
    }

    static func saveChatScale(_ scale: Double, defaults: UserDefaults = .standard) {
        defaults.set(clampChatScale(scale), forKey: chatStorageKey)
    }

    static func loadTerminalFontSize(defaults: UserDefaults = .standard) -> Double {
        if defaults.object(forKey: terminalStorageKey) != nil {
            return clampTerminalFontSize(defaults.double(forKey: terminalStorageKey))
        }
        return terminalDefaultFontSize
    }

    static func saveTerminalFontSize(_ size: Double, defaults: UserDefaults = .standard) {
        defaults.set(clampTerminalFontSize(size), forKey: terminalStorageKey)
    }
}
