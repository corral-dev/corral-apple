import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Fixture-only stand-ins for product types the pooled-list probe does not
/// exercise. Real row/model/layout code is compiled from production.

// MARK: - Design tokens not covered by the shared fixtures

enum Palette {
    static let accent = Color.accentColor
    static let assistantBubble = Color.primary.opacity(0.08)
    static let attentionWaiting = Color.yellow
    static let attentionWorking = Color.green
    static let danger = Color.red
    static let onAccent = Color.white
    static let userBubble = Color.accentColor
    static let userBubbleForeground = Color.white
}

struct ChatImageReference: Hashable {
    let id: String
}

enum ChatImageReferenceCache {
    static func references(in text: String) -> [ChatImageReference] { [] }
}

struct MessageImagesView: View {
    let seq: Int
    let references: [ChatImageReference]
    let isUser: Bool
    let userForeground: Color
    var body: some View { EmptyView() }
}

struct ToolCardView: View {
    let tool: ToolCall
    var isGrouped = false
    var body: some View { Text(tool.id) }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

enum ChatMarkdown {
    static let referenceBodyPointSize: CGFloat = 14
    static func attributed(_ text: String) -> AttributedString { AttributedString(text) }
}

enum MacMarkdownTable {
    static func apply(to mutable: NSMutableAttributedString, source: AttributedString, bodyFont: PlatformFont) {}
}

final class HapticFeedback {
    static let shared = HapticFeedback()
    enum Event { case committed, selection }
    func emit(_ event: Event) {}
}
