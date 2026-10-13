import AppKit
import SwiftUI


struct RichMessage { let seq: Int; let text: String?; let role: String }
#if !CORRAL_REAL_MARKDOWN
enum ChatMarkdown { static let referenceBodyPointSize: CGFloat = 14; static func attributed(_ text: String) -> AttributedString { AttributedString(text) } }
#endif
enum Palette {
 static let accent = Color.accentColor
 static let userBubbleForeground = Color.primary
 static let assistantBubble = Color(nsColor: .controlBackgroundColor)
}
struct ToolCall: Identifiable, Equatable { let id: String; var needsDetailFetch = false }
final class ConversationStore { func fetchToolDetails(sourceSeqs: [Int]) async -> [ToolCall]? { nil } }
struct ToolCardView: View { let tool: ToolCall; var isGrouped: Bool = false; var body: some View { Text(tool.id) } }
struct PressableButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label } }

#if !CORRAL_REAL_MARKDOWN
enum MacMarkdownTable { static func apply(to: NSMutableAttributedString, source: AttributedString, bodyFont: NSFont) {} }
#endif

final class HapticFeedback { static let shared = HapticFeedback(); enum Event { case committed }; func emit(_ event: Event) {} }
