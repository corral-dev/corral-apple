import AppKit
import Observation
import SwiftUI

// Non-rendered row data and optional media service are fixture-only. The table,
// document, Markdown, native text representable and row sizing are production.
struct ChatPromptsCardState: Equatable {}
struct ChatActivityState: Equatable {}
extension EnvironmentValues { @Entry var chatImageLoader: NSObject? = nil }

@Observable @MainActor final class BoundaryState {
    var messages: [RichMessage] = []
}

private struct BoundaryScreen: View {
    let state: BoundaryState
    let owner: NSObject

    var body: some View {
        // A persistent non-text header keeps isFirst=false for the target even
        // when it gains/loses its preceding text container.
        let rows = [MacConversationRow(id: "header", value: .earlierHistory(isLoading: false))]
            + state.messages.map {
                MacConversationRow(id: "message-\($0.seq)", value: .timeline(.message($0), separator: nil, gap: 0))
            }
        MacConversationTable(rows: rows,
                             renderKey: .init(interfaceScale: 1, sessionTextScale: 1, colorScheme: .dark,
                                              runtimeID: nil, document: ObjectIdentifier(owner)),
                             rowContent: { row in
            if case .timeline(.message(let message), _, _) = row.value {
                return AnyView(SelectableAttributedText(attributed: ChatMarkdown.attributed(message.text ?? ""))
                    .environment(\.macMessageSelectionID, message.seq))
            }
            return AnyView(Color.clear.frame(height: 8))
        }, insets: EdgeInsets(), scrollToLatestRequest: 0, scrollToMessageID: .constant(nil),
                             onLoadEarlier: nil, onFollowChange: { _ in })
            .modifier(MacConversationTextSelection(identity: ObjectIdentifier(owner), messages: state.messages))
    }
}

@main struct BoundaryProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for width in [420.0, 760] {
            let state = BoundaryState(), owner = NSObject()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: BoundaryScreen(state: state, owner: owner))
            window.contentView = host
            window.orderFront(nil)
            let before = RichMessage(seq: 1, text: "Earlier message.", role: "user")
            let target = RichMessage(seq: 2, text: "**Bold 中文 lead**\n\nBody text wraps with a final readable line.\n\n最后一行必须完整显示。", role: "assistant")
            let after = RichMessage(seq: 3, text: "Later message.", role: "user")
            for messages in [[target], [target, after], [before, target, after], [before, target], [target]] {
                state.messages = messages
                for _ in 0..<3 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    host.layoutSubtreeIfNeeded()
                    let texts = descendants(host).compactMap { $0 as? NSTextView }.filter { !$0.visibleRect.isEmpty }
                    precondition(!texts.isEmpty, "Table rendered no native text")
                    for view in texts {
                        guard let layout = view.layoutManager, let container = view.textContainer else {
                            preconditionFailure("Table lost its native text network")
                        }
                        layout.ensureLayout(for: container)
                        let used = layout.usedRect(for: container).maxY
                        precondition(ceil(used) == view.bounds.height,
                                     "Cached row clips or pads text: used=\(used), frame=\(view.bounds), width=\(width)")
                    }
                }
            }
            window.close()
        }
        print("PASS production table boundary-cache transitions: append, prepend, tail removal and history eviction")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
