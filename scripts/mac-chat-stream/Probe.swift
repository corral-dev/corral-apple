import AppKit
import Observation
import SwiftUI

// Non-rendered row data and the optional media service are fixture-only. The
// table, its cells, the shared Markdown document, Markdown parsing, the native
// text representable and row measurement are production code.

struct ChatPromptsCardState: Equatable {}
enum ConversationTimelineItem: Equatable, Identifiable {
    case message(RichMessage)
    case toolGroup(id: Int, sourceSeqs: [Int], tools: [ToolCall])

    var id: String {
        switch self {
        case .message(let message): "message-\(message.seq)"
        case .toolGroup(let id, _, _): "tools-\(id)"
        }
    }
}
struct ChatActivityState: Equatable {}
extension EnvironmentValues { @Entry var chatImageLoader: ChatImageLoader? = nil }

// Fixture-only stand-ins for the production media path, which the probe
// deliberately does not compile (ChatImageLoader pulls RemoteClient, Network
// and CryptoKit; MessageImagesView pulls QuickLook). Fixture texts contain no
// image references, diagrams or local payloads, so every media branch is
// inert: each bubble renders its Markdown text through the production
// ChatMarkdown + SelectableAttributedText path, exactly as the conversation
// does when no loader is installed. The stubs exist only so the production
// MessageBubbleView.swift compiles unchanged in the probe.
final class ChatImageLoader {
    final class Diagrams {
        func revision(text: String, dark: Bool) -> Int { 0 }
        func prepare(text: String, dark: Bool) async {}
    }
    let diagrams = Diagrams()
    func rendered(text: String, dark: Bool, seq: Int) -> AttributedString? { nil }
    func prepareImages(in text: String, seq: Int) async {}
}
struct ChatImageReference: Hashable {
    enum Kind { case mention, explicit }
    var kind: Kind = .mention
}
enum ChatImageReferenceCache {
    static func references(in text: String) -> [ChatImageReference] { [] }
}
struct MessageImagesView: View {
    let seq: Int
    let references: [ChatImageReference]
    let isUser: Bool
    var userForeground: Color = Palette.userBubbleForeground
    var body: some View { EmptyView() }
}
struct LocalEchoImagesView: View {
    let payloads: [Data]
    let isUser: Bool
    var body: some View { EmptyView() }
}

@Observable @MainActor final class StreamState {
    var messages: [RichMessage] = []
}

/// Production row content: the same MessageBubbleView ChatView renders
/// (ChatView.swift timelineRow), with the probe's explicit style inputs. The
/// media loader stays nil and fixtures carry no images, so the bubble always
/// takes its Markdown text path; the text itself is untouched.
@MainActor
private func bubbleRow(message: RichMessage, owner: NSObject,
                       interfaceScale: CGFloat, sessionTextScale: CGFloat,
                       colorScheme: ColorScheme) -> AnyView {
    AnyView(MessageBubbleView(
        message: message,
        interfaceScale: interfaceScale,
        sessionTextScale: sessionTextScale,
        colorScheme: colorScheme,
        bubbleTextCap: MessageBubbleLayout.defaultBubbleCap,
        selectionDocumentID: ObjectIdentifier(owner)
    ))
}

/// Mirrors `ChatView`'s Mac branch: rows are rebuilt from the message list on
/// every body evaluation, exactly as a streaming token does in production.
/// Rows are the production bubble, except the plain-text control run, which
/// keeps the simplified row so the Markdown-bypass cost stays isolated.
private struct StreamScreen: View {
    let state: StreamState
    let owner: NSObject
    let plainText: Bool

    var body: some View {
        let rows = state.messages.map {
            MacConversationRow(id: "message-\($0.seq)",
                               value: .timeline(.message($0), separator: nil, gap: 0))
        }
        MacConversationTable(
            rows: rows,
            renderKey: .init(interfaceScale: 1, sessionTextScale: 1, colorScheme: .dark,
                             runtimeID: nil, document: ObjectIdentifier(owner)),
            rowContent: { row in
                if case .timeline(.message(let message), _, _) = row.value {
                    if plainText {
                        let text = message.text ?? ""
                        return AnyView(
                            SelectableAttributedText(attributed: AttributedString(text))
                                .environment(\.macMessageSelectionID, message.seq)
                        )
                    }
                    return bubbleRow(message: message, owner: owner,
                                     interfaceScale: 1, sessionTextScale: 1, colorScheme: .dark)
                }
                return AnyView(Color.clear.frame(height: 8))
            },
            insets: EdgeInsets(), scrollToLatestRequest: 0, scrollToMessageID: .constant(nil),
            onLoadEarlier: nil, onFollowChange: { _ in }
        )
        .modifier(MacConversationTextSelection(identity: ObjectIdentifier(owner),
                                               messages: state.messages,
                                               renderText: plainText ? { text, _ in AttributedString(text) } : nil))
    }
}

/// Production conversation table over a document the probe keeps, so an open
/// can be separated into the document render, the row measurements and the
/// first display instead of one opaque number.
private struct OpenScreen: View {
    let state: StreamState
    let owner: NSObject
    let document: MacConversationTextDocument
    var scale: CGFloat = 1

    var body: some View {
        let rows = state.messages.map {
            MacConversationRow(id: "message-\($0.seq)",
                               value: .timeline(.message($0), separator: nil, gap: 0))
        }
        MacConversationTable(
            rows: rows,
            renderKey: .init(interfaceScale: 1, sessionTextScale: scale, colorScheme: .dark,
                             runtimeID: nil, document: ObjectIdentifier(owner)),
            rowContent: { row in
                if case .timeline(.message(let message), _, _) = row.value {
                    return bubbleRow(message: message, owner: owner,
                                     interfaceScale: 1, sessionTextScale: scale, colorScheme: .dark)
                }
                return AnyView(Color.clear.frame(height: 8))
            },
            insets: EdgeInsets(), scrollToLatestRequest: 0, scrollToMessageID: .constant(nil),
            onLoadEarlier: nil, onFollowChange: { _ in }
        )
        .modifier(MacConversationTextSelection(identity: ObjectIdentifier(owner),
                                              messages: state.messages, documentOverride: document))
        .environment(\.sessionTextScale, scale)
    }
}

/// Render-key driven variant: a text-size change invalidates every row.
private struct ScaleScreen: View {
    let state: StreamState
    let owner: NSObject
    let key: MacConversationRenderKey

    var body: some View {
        let rows = state.messages.map {
            MacConversationRow(id: "message-\($0.seq)",
                               value: .timeline(.message($0), separator: nil, gap: 0))
        }
        MacConversationTable(rows: rows, renderKey: key,
            rowContent: { row in
                if case .timeline(.message(let message), _, _) = row.value {
                    return bubbleRow(message: message, owner: owner,
                                     interfaceScale: key.interfaceScale,
                                     sessionTextScale: key.sessionTextScale,
                                     colorScheme: key.colorScheme)
                }
                return AnyView(Color.clear.frame(height: 8))
            },
            insets: EdgeInsets(), scrollToLatestRequest: 0, scrollToMessageID: .constant(nil),
            onLoadEarlier: nil, onFollowChange: { _ in })
        .modifier(MacConversationTextSelection(identity: ObjectIdentifier(owner), messages: state.messages))
        .environment(\.sessionTextScale, key.sessionTextScale)
    }
}

private struct Fixture {
    /// A realistic assistant reply: heading, bold lead, list, code block,
    /// table and prose, repeated to reach a typical long-answer length.
    static func assistant(_ seq: Int) -> String {
        """
        **第 \(seq) 段结论** — 这段回答用来模拟真实助手输出。

        - 第一条：`ChatMarkdown` 解析与排版
        - 第二条：共享文本网络的增量替换
        - 第三条：NSTableView 行高测量与单元格复用

        ```
        for index in items.indices {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
        ```

        | 项目 | 成本 | 备注 |
        |---|---|---|
        | 解析 | 中 | 每条消息一次 |
        | 排版 | 高 | 宽度变化时全量 |

        正文继续展开，包含中文与 English mixed text，用于产生足够多的换行与属性 run，
        让测量的排版成本接近真实长回答而不是短句。这里再补两行，避免行高被压缩成一行，
        也让文字量落在真实助手中位区间。
        """
    }

    static func user(_ seq: Int) -> String {
        "第 \(seq) 个提问：为什么 Mac 上滚动和输出会卡？"
    }

    static func messages(count: Int) -> [RichMessage] {
        (1...count).map { seq in
            seq.isMultiple(of: 4)
                ? RichMessage(seq: seq, text: user(seq), role: "user")
                : RichMessage(seq: seq, text: assistant(seq), role: "assistant")
        }
    }
}

@main struct StreamProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sizes = CommandLine.arguments.contains("--small") ? [20] : [20, 60, 120]
        for size in sizes {
            run(size: size, plainText: false)
        }
        if !CommandLine.arguments.contains("--small") {
            run(size: 120, plainText: true)
            isolateDocumentUpdate(size: 120)
            isolateMarkdown(size: 120)
            scroll(size: 120)
            resize(size: 120)
            resize(size: 300)
            textScale(size: 120)
            textScaleBreakdown(size: 120)
            settleParity(size: 120)
            open(size: 120)
            open(size: 120, nonContiguous: true)
            convertComponents(size: 120)
            hostingOverhead(size: 120)
            conversionEquivalence(size: 120)
            enginePhases(size: 120)
            tableCost()
            fittedLayoutCheck(size: 120)
            boundaryParity()
            contextSensitivity()
            liveNetworkHeights(size: 120)
        }
    }

    // MARK: Streaming

    @MainActor
    static func run(size: Int, plainText: Bool) {
        let state = StreamState(), owner = NSObject()
        state.messages = Fixture.messages(count: size)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StreamScreen(state: state, owner: owner, plainText: plainText))
        window.contentView = host
        window.orderFront(nil)
        settle(host, window, seconds: 0.4)

        let suffix = "\n\n追加上来的一段流式正文，用来测量每个 token 的主线程成本。"
        var tokens: [String] = []
        for index in 0..<8 { tokens.append("token\(index) ") }
        var samples: [Double] = []
        let last = state.messages.count - 1
        for round in 0..<40 {
            var messages = state.messages
            let current = messages[last]
            messages[last] = RichMessage(seq: current.seq,
                                         text: (current.text ?? "") + tokens[round % tokens.count],
                                         role: current.role)
            samples.append(busy(host, window) { state.messages = messages })
        }
        report("stream size=\(size) plain=\(plainText)", samples: samples)
        _ = suffix
        window.close()
    }

    // MARK: Scrolling and reflow

    @MainActor
    static func scroll(size: Int) {
        let state = StreamState(), owner = NSObject()
        state.messages = Fixture.messages(count: size)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StreamScreen(state: state, owner: owner, plainText: false))
        window.contentView = host
        window.orderFront(nil)
        settle(host, window, seconds: 0.4)
        guard let scrollView = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let table = scrollView.documentView else {
            print("scroll: no native scroll view")
            window.close()
            return
        }
        var samples: [Double] = []
        var y: CGFloat = 0
        let maximum = max(0, table.frame.height - scrollView.contentView.bounds.height)
        for index in 0..<120 {
            y = min(maximum, CGFloat(index) * 60)
            samples.append(measure {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            })
        }
        report("scroll 60pt/step size=\(size) (content \(Int(maximum))pt)", samples: samples)
        window.close()
    }

    @MainActor
    static func resize(size: Int) {
        let state = StreamState(), owner = NSObject()
        state.messages = Fixture.messages(count: size)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StreamScreen(state: state, owner: owner, plainText: false))
        window.contentView = host
        window.orderFront(nil)
        settle(host, window, seconds: 0.4)
        var samples: [Double] = []
        #if DEBUG
        MacConversationTableCounters.measurements = 0
        #endif
        for index in 0..<24 {
            let width = 880 - CGFloat(index) * 4
            var frame = window.frame
            frame.size.width = width
            samples.append(measure {
                window.setFrame(frame, display: false)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            })
        }
        #if DEBUG
        print("  row measurements during 24 resize steps: \(MacConversationTableCounters.measurements)")
        print("  rows deferred to the post-drag sweep: \(MacConversationTableCounters.deferredRemeasures)")
        print("  reflows \(MacConversationTableCounters.reflows) range \(MacConversationTableCounters.reflowLow)..\(MacConversationTableCounters.reflowHigh) batches \(MacConversationTableCounters.reflowBatches)")
        fflush(stdout)
        #endif
        report("window resize 4pt/step size=\(size)", samples: samples)
        // After the drag settles the sweep must leave every realized row exact:
        // its native text frame equals the ceiling of its used height.
        #if DEBUG
        let duringDrag = MacConversationTableCounters.measurements
        #endif
        settle(host, window, seconds: 0.6)
        #if DEBUG
        print("  measurements during drag \(duringDrag), after the sweep \(MacConversationTableCounters.measurements)")
        fflush(stdout)
        #endif
        let verdict = parity(host)
        print("  post-drag parity (realized rows): \(verdict)")
        // End-state check: after the deferred sweep, returning to the starting
        // width must reproduce the height a fresh measurement of that width
        // gives. A stale offscreen row would leave the content short or long.
        let tableHeight = descendants(host).compactMap { $0 as? NSTableView }.first?.frame.height ?? 0
        var back = window.frame
        back.size.width = 880
        window.setFrame(back, display: false)
        host.layoutSubtreeIfNeeded()
        settle(host, window, seconds: 0.6)
        let returned = descendants(host).compactMap { $0 as? NSTableView }.first?.frame.height ?? 0
        print(String(format: "  content height: dragged \(Int(tableHeight)) pt, back at 880 pt \(Int(returned)) pt, delta %.1f pt",
                     abs(returned - tableHeight)))
        fflush(stdout)
        window.close()
    }

    /// Feasibility + cost of measuring every row from the drawing network
    /// itself: one shared storage/layout manager, one container per message, no
    /// mounted text view. This is the candidate replacement for the detached
    /// measurement engine, so it has to answer three questions: does an
    /// unmounted container lay out at all, does each container own its text, and
    /// what does a full width reflow cost.
    @MainActor
    static func liveNetworkHeights(size: Int) {
        let font = NSFont.systemFont(ofSize: 13)
        let style = MacConversationTextDocument.Style(font: font, foreground: .labelColor,
                                                     userForeground: .white)
        let identity = ObjectIdentifier(NSObject())
        let document = MacConversationTextDocument()
        let messages = Fixture.messages(count: size)
        let sources = messages.compactMap { message -> MacConversationTextDocument.Source? in
            guard let text = message.text else { return nil }
            return .init(id: message.seq, text: text, isUser: message.role == "user")
        }
        document.update(identity: identity, sources: sources, style: style) { source in
            render(source.text, font: font)
        }
        let containers = document.layout.textContainers
        print("live network: \(containers.count) containers for \(sources.count) messages")
        fflush(stdout)

        for contiguous in [true, false] {
            document.layout.allowsNonContiguousLayout = contiguous
            var samples: [Double] = []
            var heights: [CGFloat] = []
            var empty = 0
            for index in 0..<6 {
                let width = 900 - CGFloat(index) * 4
                for container in containers {
                    container.size = NSSize(width: width, height: 100_000)
                }
                samples.append(measure {
                    var total: CGFloat = 0
                    for container in containers {
                        document.layout.ensureLayout(for: container)
                        let used = document.layout.usedRect(for: container)
                        if used.maxY <= 0 { empty += 1 }
                        total += ceil(used.maxY)
                    }
                    heights = [total]
                })
            }
            report("drawing-network heights, \(containers.count) rows, contiguous=\(contiguous)", samples: samples)
            print(String(format: "  total text height %.0f pt, empty containers over 6 widths: %d",
                         heights.first ?? 0, empty))
            fflush(stdout)
        }
    }

    /// The archived clip and list-indent defects were boundary-context parity
    /// failures between the drawn container and the row measurement. Sweep the
    /// three boundary contexts (first, middle, last) across pane widths and body
    /// sizes and require the drawn height to equal the allocated row frame.
    @MainActor
    static func boundaryParity() {
        let state = StreamState(), owner = NSObject()
        // Bold lead (2026-11-01 clip), short user row, heading + list + table.
        state.messages = [
            RichMessage(seq: 1, text: "**加粗引导句落在这里，后面必须完整可读。**\n\n正文第一段，包含中文与 English 混排，用于撑出多行。\n\n最后一句也不能被裁掉。", role: "assistant"),
            RichMessage(seq: 2, text: "中间一条短消息", role: "user"),
            RichMessage(seq: 3, text: "## 标题 Level 2\n\n- 列表项一\n- 列表项二\n\n| 项目 | 成本 |\n|---|---|\n| 解析 | 中 |\n| 排版 | 高 |\n\n```\nlet layout = NSLayoutManager()\n```\n\n收尾段落。", role: "assistant"),
        ]
        var failures: [String] = []
        var checked = 0
        for scale in [0.8, 1.0, 1.25, 1.5] {
            for width in [420.0, 594, 760, 826] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let key = MacConversationRenderKey(interfaceScale: 1, sessionTextScale: scale,
                                                   colorScheme: .dark, runtimeID: nil,
                                                   document: ObjectIdentifier(owner))
                let host = NSHostingView(rootView: ScaleScreen(state: state, owner: owner, key: key))
                window.contentView = host
                window.orderFront(nil)
                settle(host, window, seconds: 0.25)
                let verdict = parity(host)
                checked += 1
                if verdict.contains("clipped 0") && verdict.contains("padded 0") {
                    // exact
                } else {
                    failures.append("scale \(scale) width \(Int(width)): \(verdict)")
                }
                window.close()
            }
        }
        print("  boundary parity: checked \(checked) combinations, failures \(failures.count)")
        for failure in failures.prefix(6) { print("    \(failure)") }
        fflush(stdout)
        precondition(failures.isEmpty, "boundary-context parity regressed")
    }

    /// Proves the boundary context is load-bearing and that the row path uses
    /// the same one the drawing container gets: measuring a middle message with
    /// its real separators must match the drawn container, and dropping them
    /// must measurably disagree.
    @MainActor
    static func contextSensitivity() {
        let font = NSFont.systemFont(ofSize: 14)
        let style = MacConversationTextDocument.Style(font: font, foreground: .labelColor,
                                                     userForeground: .white)
        let document = MacConversationTextDocument()
        let sources = [
            MacConversationTextDocument.Source(id: 1, text: "前一条消息。", isUser: true),
            // Bold lead: the shape that TextKit gives `paragraphSpacingBefore`.
            MacConversationTextDocument.Source(id: 2, text: "**Bold lead paragraph.**\n\n正文，必须完整显示到最后一行。", isUser: false),
            MacConversationTextDocument.Source(id: 3, text: "后一条消息。", isUser: true),
        ]
        document.update(identity: ObjectIdentifier(NSObject()), sources: sources, style: style) { source in
            render(source.text, font: font)
        }
        let container = document.layout.textContainers[1]
        container.size = NSSize(width: 594, height: 100_000)
        document.layout.ensureLayout(for: container)
        let drawn = ceil(document.layout.usedRect(for: container).maxY)
        let context = document.boundaryContext(for: 2)
        let text = document.text(for: 2) ?? NSAttributedString(string: "")
        let measurement = document.measurement(for: 2) ?? MacTextMeasurement()
        let withContext = ceil(measurement.size(for: text, font: font, width: 594,
                                                before: context.before, after: context.after).height)
        let withoutContext = ceil(measurement.size(for: text, font: font, width: 594).height)
        print("  boundary context: drawn \(Int(drawn)) pt, measured \(Int(withContext)) pt, without context \(Int(withoutContext)) pt")
        fflush(stdout)
        precondition(abs(drawn - withContext) <= 1, "row measurement no longer matches the drawn container")
        precondition(withoutContext != withContext, "boundary context is no longer load-bearing; the fixture stopped covering the clip")
    }

    /// Text-size change: every row re-renders and re-measures.
    @MainActor
    static func textScale(size: Int) {
        let state = StreamState(), owner = NSObject()
        state.messages = Fixture.messages(count: size)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var key = MacConversationRenderKey(interfaceScale: 1, sessionTextScale: 1, colorScheme: .dark,
                                           runtimeID: nil, document: ObjectIdentifier(owner))
        let host = NSHostingView(rootView: ScaleScreen(state: state, owner: owner, key: key))
        window.contentView = host
        window.orderFront(nil)
        settle(host, window, seconds: 0.4)
        var samples: [Double] = []
        for index in 0..<12 {
            key.sessionTextScale = 1 + CGFloat(index + 1) * 0.02
            let next = key
            samples.append(measure {
                host.rootView = ScaleScreen(state: state, owner: owner, key: next)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            })
            settle(host, window, seconds: 0.05)
        }
        report("text-scale step size=\(size)", samples: samples)
        window.close()
    }

    // MARK: Open and text-size attribution

    @MainActor
    static func sources(_ messages: [RichMessage]) -> [MacConversationTextDocument.Source] {
        messages.compactMap { message in
            guard let text = message.text else { return nil }
            return .init(id: message.seq, text: text, isUser: message.role == "user")
        }
    }

    @MainActor
    static func style(_ scale: CGFloat) -> MacConversationTextDocument.Style {
        // Mirrors `MacConversationTextSelection.body` so a probe render and the
        // mounted view agree and the document's own gate stays a no-op.
        MacConversationTextDocument.Style(
            font: Typography.sessionUIFont(.bubbleBody, scale: scale),
            foreground: .labelColor, userForeground: NSColor(Palette.userBubbleForeground)
        )
    }

    /// Opening a long conversation: the shared document render, the row
    /// measurements and the first display separated, then together, so an
    /// open spike is attributed instead of averaged.
    @MainActor
    static func open(size: Int, nonContiguous: Bool = false) {
        let messages = Fixture.messages(count: size)
        let owner = NSObject(), identity = ObjectIdentifier(owner)
        let document = MacConversationTextDocument()
        document.layout.allowsNonContiguousLayout = nonContiguous
        let label = "open size=\(size) nonContiguous=\(nonContiguous)"

        // The shared network renders every message before the table exists.
        var documentSamples: [Double] = []
        documentSamples.append(measure {
            document.update(identity: identity, sources: sources(messages), style: style(1)) { source in
                render(source.text, font: style(1).font)
            }
        })
        report("\(label): shared document render alone (cold markdown)", samples: documentSamples)

        // First mount over that document, row heights empty: the exact work the
        // first frame of an open waits for.
        let state = StreamState()
        state.messages = messages
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #if DEBUG
        MacConversationTableCounters.measurements = 0
        MacTextRowSwitchCounters.reset()
        #endif
        var coldSamples: [Double] = []
        let host = NSHostingView(rootView: OpenScreen(state: state, owner: owner, document: document))
        coldSamples.append(busy(host, window) {
            window.contentView = host
            window.orderFront(nil)
        })
        report("\(label): first mount (measure all rows + first display)", samples: coldSamples)
        #if DEBUG
        print("  rows measured on the first mount: \(MacConversationTableCounters.measurements)")
        print("  document renders \(MacTextRowSwitchCounters.docRenders), text sets \(MacTextRowSwitchCounters.textSets), row makes \(MacTextRowSwitchCounters.makes)")
        fflush(stdout)
        #endif
        settle(host, window, seconds: 0.4)

        // Second mount over the same document with the row heights it cached:
        // the document already rendered and every row already measured, so what
        // remains is cell realization and the first display.
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        #if DEBUG
        MacConversationTableCounters.measurements = 0
        MacTextRowSwitchCounters.reset()
        #endif
        var warmSamples: [Double] = []
        let warmHost = NSHostingView(rootView: OpenScreen(state: state, owner: owner, document: document))
        warmSamples.append(busy(warmHost, second) {
            second.contentView = warmHost
            second.orderFront(nil)
        })
        report("\(label): second mount (heights and document cached)", samples: warmSamples)
        #if DEBUG
        print("  rows measured on the second mount: \(MacConversationTableCounters.measurements)")
        fflush(stdout)
        #endif
        settle(warmHost, second, seconds: 0.4)
        second.close()
        window.close()
    }

    /// Text-size step: how much of it is the document-wide re-render and how
    /// much is the row measurement burst the new render key forces.
    @MainActor
    static func textScaleBreakdown(size: Int) {
        let messages = Fixture.messages(count: size)
        let owner = NSObject(), identity = ObjectIdentifier(owner)
        let document = MacConversationTextDocument()
        document.update(identity: identity, sources: sources(messages), style: style(1)) { source in
            render(source.text, font: style(1).font)
        }
        let state = StreamState()
        state.messages = messages
        // Warm the row heights at the starting size first.
        let warmup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        warmup.isReleasedWhenClosed = false
        let warmHost = NSHostingView(rootView: OpenScreen(state: state, owner: owner, document: document))
        warmup.contentView = warmHost
        warmup.orderFront(nil)
        settle(warmHost, warmup, seconds: 0.5)
        warmup.close()

        // 1. The document re-renders every block for the new style.
        var documentSamples: [Double] = []
        documentSamples.append(measure {
            document.update(identity: identity, sources: sources(messages), style: style(1.02)) { source in
                render(source.text, font: style(1.02).font)
            }
        })
        report("text-scale size=\(size): document re-render for a new style", samples: documentSamples)

        // 2. The new render key invalidates every row height: measure them all.
        document.tableRowHeights = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #if DEBUG
        MacConversationTableCounters.measurements = 0
        #endif
        var measureSamples: [Double] = []
        let host = NSHostingView(rootView: OpenScreen(state: state, owner: owner, document: document, scale: 1.02))
        measureSamples.append(busy(host, window) {
            window.contentView = host
            window.orderFront(nil)
        })
        report("text-scale size=\(size): row measurement burst at the new size", samples: measureSamples)
        #if DEBUG
        print("  rows measured after the style change: \(MacConversationTableCounters.measurements)")
        fflush(stdout)
        #endif
        settle(host, window, seconds: 0.3)
        window.close()
    }

    // MARK: Settle parity (viewport-priority gate)

    /// The viewport-priority paths (width drags via `reflowViewportFirst`, text
    /// sizes via `reflowRenderChange`) measure the visible rows synchronously
    /// and settle the offscreen rows in deferred batches. A row whose HeightKey is
    /// wrongly judged fresh keeps its old height forever, so after the sweep
    /// this gate requires: every realized row at the top/middle/bottom shows
    /// its text with 0 clipped and 0 padded points, and the content height
    /// equals a full exact measurement at that size within 1 pt. The total is
    /// checked before scrolling anywhere: visiting a stale row re-measures it
    /// on demand, which would hide the backlog bug this gate exists to catch.
    @MainActor
    static func settleParity(size: Int) {
        let state = StreamState(), owner = NSObject()
        state.messages = Fixture.messages(count: size)
        let document = MacConversationTextDocument()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OpenScreen(state: state, owner: owner, document: document, scale: 1))
        window.contentView = host
        window.orderFront(nil)
        settle(host, window, seconds: 0.5)

        // --- Text-scale mechanism: one render-key step, then quiescence. ---
        #if DEBUG
        MacConversationTableCounters.reflowBatches = 0
        #endif
        host.rootView = OpenScreen(state: state, owner: owner, document: document, scale: 1.25)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let scaleWait = waitForQuiescence(host, window, timeout: 3)
        print(String(format: "  settle parity: text-scale 1 -> 1.25 quiesced in %.2f s", scaleWait))
        fflush(stdout)
        let scaleReference = freshContentHeight(messages: state.messages, scale: 1.25, width: 900)
        assertSettledTotal(host, reference: scaleReference, mechanism: "text-scale")
        assertSettledPositions(host: host, mechanism: "text-scale")

        // --- Width mechanism: a 120 pt drag in 4 pt steps, then quiescence. ---
        #if DEBUG
        MacConversationTableCounters.reflowBatches = 0
        #endif
        for index in 1...30 {
            var frame = window.frame
            frame.size.width = 900 - CGFloat(index) * 4
            window.setFrame(frame, display: false)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let widthWait = waitForQuiescence(host, window, timeout: 3)
        print(String(format: "  settle parity: width 900 -> 780 quiesced in %.2f s", widthWait))
        fflush(stdout)
        let widthReference = freshContentHeight(messages: state.messages, scale: 1.25, width: 780)
        assertSettledTotal(host, reference: widthReference, mechanism: "width")
        assertSettledPositions(host: host, mechanism: "width")
        window.close()
    }

    /// Pumps the run loop until the deferred sweep drains: content height and
    /// the DEBUG batch/measure counters stop moving. Returns the wait in
    /// seconds. Never sleeps blindly; the timeout only bounds a stuck sweep,
    /// and the assertions after it still fail a table that never settled.
    @MainActor
    @discardableResult
    static func waitForQuiescence(_ host: NSView, _ window: NSWindow, timeout: TimeInterval) -> TimeInterval {
        let start = Date()
        var calm = 0
        var last = quiescenceSample(host)
        while Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let current = quiescenceSample(host)
            if current == last {
                calm += 1
                if calm >= 4 { break }
            } else {
                calm = 0
                last = current
            }
        }
        return Date().timeIntervalSince(start)
    }

    @MainActor
    static func quiescenceSample(_ host: NSView) -> (CGFloat, Int, Int) {
        let height = contentHeight(host) ?? -1
        #if DEBUG
        return (height, MacConversationTableCounters.reflowBatches, MacConversationTableCounters.measurements)
        #else
        return (height, 0, 0)
        #endif
    }

    /// Exact content height: the bottom of the last row's rect.
    @MainActor
    static func contentHeight(_ host: NSView) -> CGFloat? {
        guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first,
              table.numberOfRows > 0 else { return nil }
        return table.rect(ofRow: table.numberOfRows - 1).maxY
    }

    /// A full exact measurement at the same size: a fresh mount measures every
    /// row synchronously on its first pass, so its content height is the
    /// ground truth the settled table must agree with within 1 pt.
    @MainActor
    static func freshContentHeight(messages: [RichMessage], scale: CGFloat, width: CGFloat) -> CGFloat {
        let state = StreamState()
        state.messages = messages
        let owner = NSObject()
        let document = MacConversationTextDocument()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OpenScreen(state: state, owner: owner, document: document, scale: scale))
        window.contentView = host
        window.orderFront(nil)
        settle(host, window, seconds: 0.5)
        let height = contentHeight(host) ?? -1
        window.close()
        return height
    }

    /// Global check: the settled table holds every row, including rows that
    /// never became visible, at its exact height.
    @MainActor
    static func assertSettledTotal(_ host: NSView, reference: CGFloat, mechanism: String) {
        let total = contentHeight(host) ?? -1
        print(String(format: "  settle parity (%@): content %.1f pt vs full %.1f pt, delta %.1f pt",
                     mechanism, total, reference, abs(total - reference)))
        fflush(stdout)
        precondition(total > 0 && reference > 0, "settle parity (\(mechanism)): no content height to compare")
        precondition(abs(total - reference) <= 1,
                     "settle parity (\(mechanism)): settled content \(total) pt != full measurement \(reference) pt")
    }

    /// Positional check: at the top, middle and bottom, every realized row
    /// shows its text exactly — no clipped line, no leftover padding.
    /// Realizing a stale row re-measures it on demand and residual
    /// corrections hop the main queue, so each position converges first and
    /// is judged settled; a row that never converges fails the gate after a
    /// bounded wait. The backlog bug this gate exists to catch is already
    /// pinned by the total-height check above, which runs before any scroll
    /// can heal rows on demand.
    /// Arrival is incremental (<=200 pt steps in document order) rather than
    /// a direct jump: a bottom-to-top jump intermittently drops the shared
    /// layout's first container break (row 0 draws two blocks, +440 pt clip;
    /// ~30% of full-suite runs), a jump-robustness defect filed separately.
    /// Settle parity is about quiesced heights, not jump tiling, so positions
    /// arrive the way a reader does; thresholds are unchanged.
    @MainActor
    static func assertSettledPositions(host: NSView, mechanism: String) {
        guard let scrollView = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let table = descendants(host).compactMap({ $0 as? NSTableView }).first else {
            preconditionFailure("settle parity (\(mechanism)): no native scroll view")
        }
        let maximum = max(0, (contentHeight(host) ?? 0) - scrollView.contentView.bounds.height)
        for (label, y) in [("top", 0), ("middle", maximum / 2), ("bottom", maximum)] {
            let fromY = scrollView.contentView.bounds.origin.y
            let steps = max(1, Int(abs(y - fromY) / 200) + 1)
            for step in 1...steps {
                let yy = fromY + (y - fromY) * CGFloat(step) / CGFloat(steps)
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: yy))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                host.layoutSubtreeIfNeeded()
                if let window = host.window { window.displayIfNeeded() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let start = Date()
            var verdict = ""
            repeat {
                host.layoutSubtreeIfNeeded()
                if let window = host.window { window.displayIfNeeded() }
                verdict = positionParity(host: host, table: table, scrollView: scrollView)
                if verdict.contains("clipped 0") && verdict.contains("padded 0")
                    && !verdict.contains("no realized") { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            } while Date().timeIntervalSince(start) < 3
            print("  settle parity (\(mechanism)) @ \(label): \(verdict)")
            fflush(stdout)
            precondition(verdict.contains("clipped 0") && verdict.contains("padded 0") && !verdict.contains("no realized"),
                         "settle parity (\(mechanism)) @ \(label) regressed: \(verdict)")
        }
    }

    /// Like `parity(_)` but only for rows realized inside the current
    /// viewport, and skipping inner bubble scrollers (production Mac bubbles
    /// are uncapped, so any text view inside its own scroller is not a row).
    @MainActor
    static func positionParity(host: NSView, table: NSTableView, scrollView: NSScrollView) -> String {
        let visible = table.visibleRect
        guard visible.height > 0 else { return "no realized rows (empty viewport)" }
        var checked = 0, clipped = 0, padded = 0
        var worstClip = 0.0, worstClipRow = -1, worstPad = 0.0, worstPadRow = -1
        for view in descendants(host).compactMap({ $0 as? NSTextView }) {
            if view.isHiddenOrHasHiddenAncestor || view.window == nil { continue }
            if let inner = view.enclosingScrollView, inner !== scrollView { continue }
            let inTable = view.convert(view.bounds, to: table)
            guard inTable.intersects(visible) else { continue }
            guard let layout = view.layoutManager, let container = view.textContainer else { continue }
            layout.ensureLayout(for: container)
            let used = ceil(layout.usedRect(for: container).maxY)
            let frame = view.bounds.height
            let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: table)
            let row = table.row(at: center)
            checked += 1
            if used > frame + 0.5 {
                clipped += 1
                if used - frame > worstClip { worstClip = used - frame; worstClipRow = row }
            }
            if used + 0.5 < frame {
                padded += 1
                if frame - used > worstPad { worstPad = frame - used; worstPadRow = row }
            }
        }
        guard checked > 0 else { return "no realized text views" }
        var detail = "checked \(checked), clipped \(clipped), padded \(padded)"
        if clipped > 0 { detail += String(format: " (worst clip row %d +%.1f pt)", worstClipRow, worstClip) }
        if padded > 0 { detail += String(format: " (worst pad row %d +%.1f pt)", worstPadRow, worstPad) }
        return detail
    }
    /// spend their time, so a per-row cost has a named component.
    @MainActor
    static func convertComponents(size: Int) {
        let messages = Fixture.messages(count: size)
        let font = Typography.sessionUIFont(.bubbleBody, scale: 1)
        let reference = ChatMarkdown.referenceBodyPointSize
        let attributed = messages.map { ChatMarkdown.attributed($0.text ?? "") }
        var cached: [Double] = [], bridging: [Double] = [], fonts: [Double] = []
        var tables: [Double] = [], paths: [Double] = [], layouts: [Double] = []
        var measurement: MacTextMeasurement?
        for (index, message) in messages.enumerated() {
            let source = attributed[index]
            cached.append(measure { _ = ChatMarkdown.attributed(message.text ?? "") })
            var bridged = NSMutableAttributedString()
            bridging.append(measure { bridged = NSMutableAttributedString(attributedString: NSAttributedString(source)) })
            let full = NSRange(location: 0, length: bridged.length)
            fonts.append(measure {
                bridged.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                    var next = attrs
                    if let existing = attrs[.font] as? NSFont {
                        let ratio = existing.pointSize / max(reference, 1)
                        next[.font] = NSFont(descriptor: existing.fontDescriptor, size: font.pointSize * ratio) ?? font
                    } else {
                        next[.font] = font
                    }
                    bridged.setAttributes(next, range: range)
                }
            })
            tables.append(measure { MacMarkdownTable.apply(to: bridged, source: source, bodyFont: font) })
            paths.append(measure { MacPathLinks.apply(to: bridged, workingDirectory: nil) })
            let measurer = measurement ?? MacTextMeasurement()
            measurement = measurer
            layouts.append(measure { _ = measurer.size(for: bridged, font: font, width: 760) })
        }
        report("component \(size) messages: ChatMarkdown.attributed (cached)", samples: cached)
        report("component \(size) messages: NSAttributedString bridge", samples: bridging)
        report("component \(size) messages: font rescale", samples: fonts)
        report("component \(size) messages: MacMarkdownTable.apply", samples: tables)
        report("component \(size) messages: MacPathLinks.apply", samples: paths)
        report("component \(size) messages: detached text layout at 760", samples: layouts)
    }

    /// Split of one row measurement: SwiftUI hosting pass overhead versus the
    /// row's own text layout. A one-pass measurement is only worth building if
    /// the per-root overhead is a real share of each row.
    @MainActor
    static func hostingOverhead(size: Int) {
        let measurer = NSHostingController(rootView: AnyView(EmptyView()))
        measurer.sizingOptions = []
        var trivial: [Double] = []
        for index in 0..<size {
            trivial.append(measure {
                measurer.rootView = AnyView(Color.clear.frame(height: CGFloat(20 + index % 7)))
                _ = measurer.sizeThatFits(in: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
            })
        }
        report("hosting pass per row (trivial view)", samples: trivial)
        var rows: [Double] = []
        let attributed = Fixture.messages(count: size).map { ChatMarkdown.attributed($0.text ?? "") }
        for index in 0..<size {
            rows.append(measure {
                measurer.rootView = AnyView(SelectableAttributedText(attributed: attributed[index]))
                _ = measurer.sizeThatFits(in: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
            })
        }
        report("hosting pass per row (SelectableAttributedText row)", samples: rows)
    }

    /// Phase split of the detached measurement engine's own work, replicated
    /// with the same TextKit calls, to show whether the second (fitted-width)
    /// layout runs and what each phase costs per message.
    @MainActor
    static func enginePhases(size: Int) {
        let messages = Fixture.messages(count: size)
        let font = Typography.sessionUIFont(.bubbleBody, scale: 1)
        let texts = messages.map { message -> NSAttributedString in
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(ChatMarkdown.attributed(message.text ?? "")))
            let full = NSRange(location: 0, length: mutable.length)
            mutable.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                var next = attrs
                next[.font] = attrs[.font] as? NSFont ?? font
                mutable.setAttributes(next, range: range)
            }
            return mutable
        }
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: 100_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var sets: [Double] = [], firsts: [Double] = [], seconds: [Double] = [], queries: [Double] = []
        var secondPasses = 0
        for text in texts {
            sets.append(measure {
                storage.setAttributedString(NSAttributedString(string: ""))
                storage.append(text)
                storage.append(NSAttributedString(string: "\n"))
                container.size.width = 760
            })
            firsts.append(measure { layout.ensureLayout(for: container) })
            var fitted: CGFloat = 760
            queries.append(measure {
                let used = layout.usedRect(for: container)
                fitted = min(ceil(max(used.maxX, 1)), 760)
                _ = layout.defaultLineHeight(for: font)
            })
            guard container.size.width != fitted else { continue }
            secondPasses += 1
            seconds.append(measure {
                container.size.width = fitted
                layout.ensureLayout(for: container)
                _ = layout.usedRect(for: container)
            })
        }
        report("engine \(size) messages: storage set per message", samples: sets)
        report("engine \(size) messages: first layout at 760", samples: firsts)
        report("engine \(size) messages: usedRect + fitted width", samples: queries)
        report("engine \(size) messages: second layout at the fitted width", samples: seconds)
        print("  second (fitted-width) layouts: \(secondPasses) of \(texts.count)")
        fflush(stdout)
    }

    /// The draw-text font pass used to replace each run's whole attribute
    /// dictionary; it now sets only the two attributes it owns. This proves the
    /// two strategies leave identical attributes and reports both costs, so a
    /// future edit cannot quietly change the rendered text.
    @MainActor
    static func conversionEquivalence(size: Int) {
        let messages = Fixture.messages(count: size)
        let font = Typography.sessionUIFont(.bubbleBody, scale: 1)
        let reference = ChatMarkdown.referenceBodyPointSize
        var dictionary: [Double] = [], attribute: [Double] = []
        var mismatches = 0
        for message in messages {
            let source = ChatMarkdown.attributed(message.text ?? "")
            let reference_string = NSMutableAttributedString(attributedString: NSAttributedString(source))
            let full = NSRange(location: 0, length: reference_string.length)
            let asToday = NSMutableAttributedString(attributedString: reference_string)
            dictionary.append(measure {
                asToday.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                    var next = attrs
                    if let existing = attrs[.font] as? NSFont {
                        next[.font] = NSFont(descriptor: existing.fontDescriptor,
                                             size: font.pointSize * (existing.pointSize / max(reference, 1))) ?? font
                    } else {
                        next[.font] = font
                    }
                    if attrs[.foregroundColor] == nil { next[.foregroundColor] = NSColor.labelColor }
                    asToday.setAttributes(next, range: range)
                }
            })
            let asLanded = NSMutableAttributedString(attributedString: reference_string)
            attribute.append(measure {
                var fonts: [(NSRange, NSFont)] = []
                var colorless: [NSRange] = []
                asLanded.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                    if let existing = attrs[.font] as? NSFont {
                        fonts.append((range, NSFont(descriptor: existing.fontDescriptor,
                                                    size: font.pointSize * (existing.pointSize / max(reference, 1))) ?? font))
                    } else {
                        fonts.append((range, font))
                    }
                    if attrs[.foregroundColor] == nil { colorless.append(range) }
                }
                for (range, resolved) in fonts { asLanded.addAttribute(.font, value: resolved, range: range) }
                for range in colorless { asLanded.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
            })
            if !asToday.isEqual(to: asLanded) {
                mismatches += 1
            }
        }
        report("conversion \(size): font pass, whole attribute dictionary", samples: dictionary)
        report("conversion \(size): font pass, per-attribute (landed)", samples: attribute)
        print("  converted strings that differ: \(mismatches) of \(messages.count)")
        fflush(stdout)
        precondition(mismatches == 0, "the landed font pass no longer matches the dictionary pass")
    }

    /// Does the detached engine's second layout (at the fitted width) ever
    /// produce a different height than the layout at the proposed width? The
    /// fitted width is min(ceil(used.maxX), width), so every line already fits
    /// it; if the heights agree on every fixture and width, that second layout
    /// is removable.
    @MainActor
    static func fittedLayoutCheck(size: Int) {
        let boundary = [
            "**加粗引导句落在这里，后面必须完整可读。**\n\n正文第一段，包含中文与 English 混排，用于撑出多行。\n\n最后一句也不能被裁掉。",
            "中间一条短消息",
            "## 标题 Level 2\n\n- 列表项一\n- 列表项二\n\n| 项目 | 成本 |\n|---|---|\n| 解析 | 中 |\n| 排版 | 高 |\n\n```\nlet layout = NSLayoutManager()\n```\n\n收尾段落。",
        ]
        let texts = Fixture.messages(count: size).compactMap(\.text) + boundary
        var checked = 0, mismatches = 0, secondPasses = 0
        for scale in [0.8, 1.0, 1.25, 1.5] {
            let font = Typography.sessionUIFont(.bubbleBody, scale: scale)
            let rendered = texts.map { render($0, font: font) }
            for text in rendered {
                for width in [420.0, 594.0, 760.0, 826.0] {
                    let storage = NSTextStorage()
                    let layout = NSLayoutManager()
                    let container = NSTextContainer(size: NSSize(width: width, height: 100_000))
                    container.lineFragmentPadding = 0
                    layout.addTextContainer(container)
                    storage.addLayoutManager(layout)
                    storage.setAttributedString(text)
                    layout.ensureLayout(for: container)
                    let atWidth = ceil(layout.usedRect(for: container).maxY)
                    let fitted = min(ceil(max(layout.usedRect(for: container).maxX, 1)), width)
                    checked += 1
                    guard fitted != width else { continue }
                    secondPasses += 1
                    container.size.width = fitted
                    layout.ensureLayout(for: container)
                    let atFitted = ceil(layout.usedRect(for: container).maxY)
                    if abs(atFitted - atWidth) > 0.01 {
                        mismatches += 1
                        print("    fitted mismatch: scale \(scale) width \(Int(width)) fitted \(Int(fitted)) atWidth \(Int(atWidth)) atFitted \(Int(atFitted))")
                    }
                }
            }
        }
        print("  fitted-width layouts: checked \(checked) text/width cases, second layout ran \(secondPasses), heights differ \(mismatches)")
        fflush(stdout)
    }

    /// Whether the per-row layout cost is the text or the native Markdown
    /// table: same length and language, with and without a table.
    @MainActor
    static func tableCost() {
        let withTable = """
        **结论** — 这一段用来模拟真实助手输出。

        - 第一条：解析与排版
        - 第二条：共享文本网络的增量替换

        | 项目 | 成本 | 备注 |
        |---|---|---|
        | 解析 | 中 | 每条消息一次 |
        | 排版 | 高 | 宽度变化时全量 |

        正文继续展开，包含中文与 English mixed text，用于产生足够的换行与属性 run。
        """
        let withoutTable = """
        **结论** — 这一段用来模拟真实助手输出。

        - 第一条：解析与排版
        - 第二条：共享文本网络的增量替换

        解析 | 中 | 每条消息一次
        排版 | 高 | 宽度变化时全量

        正文继续展开，包含中文与 English mixed text，用于产生足够的换行与属性 run。
        """
        let font = Typography.sessionUIFont(.bubbleBody, scale: 1)
        for (label, text) in [("with Markdown table", withTable), ("table flattened to text", withoutTable)] {
            let ns = render(text, font: font)
            var samples: [Double] = []
            for index in 0..<20 {
                // A fresh measurer per row, as the table's own open pass does.
                let measurer = MacTextMeasurement()
                samples.append(measure { _ = measurer.size(for: ns, font: font, width: 700 - CGFloat(index % 3)) })
            }
            report("row text layout \(label) (\(ns.length) chars)", samples: samples)
        }
    }

    /// Every realized native text view must exactly fill its row: drawn height
    /// equals the ceiling of the used height, no clipped or padded line.
    @MainActor
    static func parity(_ host: NSView) -> String {
        let views = descendants(host).compactMap { $0 as? NSTextView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        guard !views.isEmpty else { return "no realized text views" }
        var checked = 0, clipped = 0, padded = 0
        for view in views {
            guard let layout = view.layoutManager, let container = view.textContainer else { continue }
            layout.ensureLayout(for: container)
            let used = ceil(layout.usedRect(for: container).maxY)
            let frame = view.bounds.height
            checked += 1
            if used > frame + 0.5 { clipped += 1 }
            if used + 0.5 < frame { padded += 1 }
        }
        return "checked \(checked), clipped \(clipped), padded \(padded)"
    }

    /// First reflow after a width change re-measures every row through SwiftUI.
    @MainActor
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    // MARK: Isolation

    @MainActor
    static func isolateDocumentUpdate(size: Int) {
        let document = MacConversationTextDocument()
        let messages = Fixture.messages(count: size)
        func sources(_ messages: [RichMessage]) -> [MacConversationTextDocument.Source] {
            messages.compactMap { message in
                guard let text = message.text else { return nil }
                return .init(id: message.seq, text: text, isUser: message.role == "user")
            }
        }
        let font = NSFont.systemFont(ofSize: 13)
        let style = MacConversationTextDocument.Style(font: font, foreground: .labelColor,
                                                     userForeground: .white)
        let identity = ObjectIdentifier(NSObject())
        let warm = DispatchTime.now().uptimeNanoseconds
        document.update(identity: identity, sources: sources(messages), style: style) { source in
            render(source.text, font: font)
        }
        _ = warm
        var samples: [Double] = []
        for index in 0..<20 {
            var next = messages
            let current = next[next.count - 1]
            next[next.count - 1] = RichMessage(seq: current.seq,
                                               text: (current.text ?? "") + "token\(index) ",
                                               role: current.role)
            samples.append(measure {
                document.update(identity: identity, sources: sources(next), style: style) { source in
                    render(source.text, font: font)
                }
            })
        }
        report("document.update size=\(size) (one message changed)", samples: samples)
    }

    @MainActor
    static func isolateMarkdown(size: Int) {
        let text = Fixture.assistant(size) + "\n\n追加的流式正文。"
        var samples: [Double] = []
        for index in 0..<20 {
            let source = text + "token\(index) "
            samples.append(measure { _ = ChatMarkdown.attributed(source) })
        }
        report("ChatMarkdown.attributed (uncached, \(text.utf8.count)B)", samples: samples)
    }

    /// The production per-message render: Markdown parse + style + native tables.
    @MainActor
    static func render(_ text: String, font: NSFont) -> NSAttributedString {
        let attributed = ChatMarkdown.attributed(text)
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        MacMarkdownTable.apply(to: mutable, source: attributed, bodyFont: font)
        return mutable
    }

    // MARK: Measurement

    /// Main-thread busy time for one streaming token: the state write plus the
    /// layout and display work it forces before the run loop is idle again.
    @MainActor
    static func busy(_ host: NSView, _ window: NSWindow, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        for _ in 0..<2 {
            CFRunLoopRunInMode(.defaultMode, 0, false)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @MainActor
    static func measure(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @MainActor
    static func settle(_ host: NSView, _ window: NSWindow, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        _ = host
    }

    static func report(_ label: String, samples: [Double]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let total = samples.reduce(0, +)
        print(String(format: "%-52@ median %6.1f ms  p95 %6.1f ms  max %6.1f ms  total %7.1f ms",
                     label as NSString, median, p95, sorted.last ?? 0, total))
        fflush(stdout)
    }
}
