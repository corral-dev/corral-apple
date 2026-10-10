import AppKit
import SwiftUI
import Observation

struct RichMessage { let seq: Int; let text: String?; let role: String }
enum ChatMarkdown {
    static let referenceBodyPointSize: CGFloat = 14
    static func attributed(_ text: String) -> AttributedString { AttributedString(text) }
}
enum Palette {
    static let accent = Color.accentColor
    static let userBubbleForeground = Color.primary
}
enum MacMarkdownTable {
    static func apply(to: NSMutableAttributedString, source: AttributedString, bodyFont: NSFont) {}
}
@Observable final class MacWorkspace {
    var paneShifts: [String: CGFloat] = [:]
    var leavingPanes: [String: Bool] = [:]
}
enum MacSplitArea { static let paneMinimum: CGFloat = 220 }
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
final class HapticFeedback {
    static let shared = HapticFeedback()
    enum Event { case committed }
    func emit(_ event: Event) {}
}
