import AppKit
import SwiftUI


struct RichMessage: Equatable {
    let seq: Int
    let text: String?
    let role: String
    /// Production bubble inputs the fixture must also carry. Fixtures never
    /// fail and never carry images, so these stay at their quiet defaults and
    /// existing three-argument constructions keep compiling.
    var delivery: MessageDelivery = .sent
    var failureDetail: String? = nil
    var localImageData: [Data] = []
    var hasLocalImages: Bool { !localImageData.isEmpty }
    var chatBodyText: String? { text }
}
/// Quiet subset of the production delivery states: only failed/needsReview
/// render extra feedback under the bubble, which fixtures never exercise.
enum MessageDelivery: Equatable {
    case sent
    case failed
    case needsReview
}
#if !CORRAL_REAL_MARKDOWN
enum ChatMarkdown { static let referenceBodyPointSize: CGFloat = 14; static func attributed(_ text: String) -> AttributedString { AttributedString(text) } }
#endif
enum Palette {
 static let accent = Color.accentColor
 static let userBubbleForeground = Color.primary
 static let assistantBubble = Color(nsColor: .controlBackgroundColor)
 /// Fixture-only stand-ins for the asset-catalog bubble colors (absent from
 /// the probe bundle): row heights never depend on fill colors.
 static let userBubble = Color(nsColor: .selectedControlColor)
 static let danger = Color(nsColor: .systemRed)
}
struct ToolCall: Identifiable, Equatable { let id: String; var needsDetailFetch = false }
final class ConversationStore { func fetchToolDetails(sourceSeqs: [Int]) async -> [ToolCall]? { nil } }
struct ToolCardView: View { let tool: ToolCall; var isGrouped: Bool = false; var body: some View { Text(tool.id) } }
struct PressableButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label } }

#if !CORRAL_REAL_MARKDOWN
enum MacMarkdownTable { static func apply(to: NSMutableAttributedString, source: AttributedString, bodyFont: NSFont) {} }
#endif

final class HapticFeedback { static let shared = HapticFeedback(); enum Event { case committed }; func emit(_ event: Event) {} }
