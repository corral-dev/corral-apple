#if DEBUG && os(iOS)
import SwiftUI

/// Same installed application and production chat/table path. Synthetic data
/// stays in memory and never creates, edits or submits a real session.
struct MarkdownTableInspection: View {
    @State private var store: ConversationStore
    @State private var loader: ChatImageLoader

    init() {
        let store = ConversationStore(sessionKey: "table-inspection", client: nil, live: false)
        let loader = ChatImageLoader(client: nil, hostID: "table-inspection", sessionKey: "fixture")
        loader.localPreview = Self.previewImage()
        let diagrams = ProcessInfo.processInfo.arguments.contains("-CorralInspectMarkdownDiagrams")
        var messages = diagrams ? [
            RichMessage(seq: 1, role: "assistant", text: """
            Mermaid 流程图：

            ```mermaid
            flowchart LR
              A[读取消息] --> B{已缓存?}
              B -->|是| C[显示图表]
              B -->|否| D[本地渲染]
              D --> C
            ```

            PlantUML 时序图：

            ```plantuml
            @startuml
            participant "iPhone 客户端" as Phone
            participant "本地渲染器" as Renderer
            Phone -> Renderer : 绘制图表
            Renderer --> Phone : 完成
            @enduml
            """),
        ] : [
            RichMessage(seq: 1, role: "assistant", text: """
            表格在手机上按行铺开，每行一条列表，第一列做标题。

            | 名称 | 状态 | 备注 |
            |:---|:---:|:---|
            | Auth | 已完成 | 支持 JWT 与 OAuth2 |
            | Payment | 进行中 | 正在对接 Stripe |
            """),
            RichMessage(seq: 2, role: "assistant", text: """
            宽表也一样：所有字段都在列表里，不需要左右滑。

            | Format | Mac | iPhone | Offline | Copy | Notes |
            |:---|:---:|:---:|:---:|:---:|---|
            | Image | Yes | Yes | Cached | Yes | Original media preview |
            | Mermaid | Yes | Yes | Yes | Source | Flow, sequence and mindmap |
            | PlantUML | Yes | Yes | Yes | Source | Activity, class and C4 |
            | 空单元格 | | | | | 中文 👨‍👩‍👧‍👦 |
            """),
            RichMessage(seq: 3, role: "assistant", text: """
            图片应当出现在 Markdown 引用它的位置。

            ![本地图片](corral-preview://LocalImage.png)

            图片后面的文字仍然在图片之后。
            """),
        ]
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectLongMessage"),
           let encoded = ProcessInfo.processInfo.environment["CORRAL_SCROLL_SOURCE_BASE64"],
           let data = Data(base64Encoded: encoded), let source = String(data: data, encoding: .utf8) {
            messages = [RichMessage(seq: 1, role: "assistant", text: source.replacingOccurrences(
                of: "apple/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png", with: "corral-preview://LocalImage.png"
            ))]
        }
        if let data = try? JSONEncoder().encode(messages),
           let list = try? JSONSerialization.jsonObject(with: data),
           let payload = try? JSONSerialization.data(withJSONObject: ["messages": list, "oldest_seq": 1, "newest_seq": messages.count]),
           let snapshot = try? JSONDecoder().decode(SessionMessagesResponse.self, from: payload) {
            store.applySnapshot(snapshot)
        }
        _store = State(initialValue: store)
        _loader = State(initialValue: loader)
    }

    /// Local bitmap only for this Debug inspection; the production path still
    /// loads every image from the paired host.
    private static func previewImage() -> UIImage {
        let size = CGSize(width: 900, height: 600)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.09, green: 0.38, blue: 0.28, alpha: 1).cgColor,
                          UIColor(red: 0.95, green: 0.72, blue: 0.18, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let text = "INLINE IMAGE" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 88, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
    }

    private func inspectLongScrollIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectLongMessageScroll") else { return }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        var textView: UITextView?
        for _ in 0..<80 {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            textView = windows.flatMap(descendants).compactMap { $0 as? UITextView }.first {
                !$0.isEditable && $0.isScrollEnabled && $0.bounds.height > 100 && ($0.text?.count ?? 0) > 1000
            }
            if textView != nil { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard let textView else { return }
        var samples: [[String: Any]] = []
        for (step, y) in [0.0, 280, 560, 840, 560, 280, 0].enumerated() {
            let maximum = max(0, textView.contentSize.height - textView.bounds.height)
            let target = min(y, maximum)
            textView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            textView.layoutIfNeeded()
            samples.append(["step": step, "requested": target, "actual": textView.contentOffset.y,
                            "height": textView.contentSize.height, "viewport": textView.bounds.height])
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let data = try? JSONSerialization.data(withJSONObject: ["samples": samples], options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("bubble-scroll-inspection.json"), options: .atomic)
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    var body: some View {
        NavigationStack {
            ChatView(store: store, runtimeID: "pi")
                .environment(\.chatImageLoader, loader)
                .navigationTitle("Chat rendering")
                .task { await inspectLongScrollIfRequested() }
        }
    }
}
#endif
