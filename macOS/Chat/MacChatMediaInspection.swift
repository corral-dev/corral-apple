#if DEBUG
import AppKit
import SwiftUI

/// Opt-in fixture inside the actual client; no history writes, pointer input,
/// preferences or pairing changes. Saves numeric/copy evidence, not sources.
@MainActor
enum MacChatMediaInspection {
    private static var started = false
    private static var window: NSWindow?
    static func runIfRequested(model: AppModel) async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectChatMedia"), !started else { return }
        started = true
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectMediaLive") {
            await inspectLive(model: model)
            return
        }
        let loader = ChatImageLoader(client: nil, hostID: "media-inspection", sessionKey: "fixture")
        let text = """
        Image and diagram acceptance

        ```mermaid
        flowchart LR
          A[读取消息] --> B{已缓存?}
          B -->|是| C[显示图表]
          B -->|否| D[本地渲染]
          D --> C
        ```

        Between the two drawings: selectable native text.

        ```plantuml
        @startuml
        participant "Mac 客户端" as Mac
        participant "本地渲染器" as Renderer
        Mac -> Renderer : 绘制图表
        Renderer --> Mac : 完成
        @enduml
        ```

        End of the same native message.
        """
        let store = ConversationStore(sessionKey: "media-inspection", client: nil, live: false)
        let message = RichMessage(seq: 1, role: "assistant", text: text)
        guard let data = try? JSONEncoder().encode([message]),
              let list = try? JSONSerialization.jsonObject(with: data),
              let payload = try? JSONSerialization.data(withJSONObject: ["messages": list, "oldest_seq": 1, "newest_seq": 1]),
              let snapshot = try? JSONDecoder().decode(SessionMessagesResponse.self, from: payload) else { return }
        store.applySnapshot(snapshot)
        let dark = ProcessInfo.processInfo.arguments.contains("-CorralInspectMediaDark")
        let document = MacConversationTextDocument()
        let root = NSHostingView(rootView: ChatView(store: store, runtimeID: "pi")
            .environment(model).environment(\.chatImageLoader, loader)
            .environment(\.macConversationTextDocument, document)
            .environment(\.colorScheme, dark ? .dark : .light)
            .sheet(item: Binding(get: { loader.diagrams.inspection }, set: { loader.diagrams.inspection = $0 })) { ChatDiagramViewer(inspection: $0) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 850, height: 1000),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Corral Chat Media"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = root
        window.orderBack(nil)
        self.window = window
        // Use the same lazy production renderer and then let Observation update
        // the native document/table. No separate web preview is substituted.
        let blocks = ChatMarkdown.diagrams(in: text)
        await loader.diagrams.prepare(text: text, dark: dark)
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectMediaViewer"),
           let block = blocks.first,
           let drawing = ChatDiagramRenderer.shared.cached(host: loader.diagrams.hostID, block: block, dark: dark) {
            loader.diagrams.inspection = ChatDiagramInspection(drawing: drawing, source: block.original)
        }
        try? await Task.sleep(for: .seconds(2))
        let native = document.storage
        var attachments: [ChatDiagramAttachment] = []
        native.enumerateAttribute(.attachment, in: NSRange(location: 0, length: native.length)) { value, _, _ in
            if let attachment = value as? ChatDiagramAttachment { attachments.append(attachment) }
        }
        let copied = ChatDiagramAttachment.plainText(native, range: NSRange(location: 0, length: native.length)) ?? ""
        var report: [String: Any] = ["attachments": attachments.count,
            "sourceCopy": blocks.allSatisfy { copied.contains($0.original) },
            "adjacentText": copied.contains("Between the two drawings"),
            "revision": loader.diagrams.revision(text: text, dark: dark), "dark": dark]
        var renders: [[String: Any]] = []
        for block in blocks {
            if let drawing = ChatDiagramRenderer.shared.cached(host: loader.diagrams.hostID, block: block, dark: dark) {
                renders.append(["type": block.kind.rawValue, "pdfBytes": drawing.pdf.count,
                                "width": drawing.size.width, "height": drawing.size.height])
            }
        }
        report["drawings"] = renders
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectMediaMatrix") {
            let matrix: [(String, ChatDiagramBlock.Kind, String)] = [
                ("sequence", .mermaid, "sequenceDiagram\nAlice->>Bob: Hello\nBob-->>Alice: Done"),
                ("class", .mermaid, "classDiagram\nclass Message\nclass Drawing\nMessage --> Drawing"),
                ("state", .mermaid, "stateDiagram-v2\n[*] --> Loading\nLoading --> Ready\nReady --> [*]"),
                ("er", .mermaid, "erDiagram\nMESSAGE ||--o{ DRAWING : contains"),
                ("mindmap", .mermaid, "mindmap\n  root((中文图表))\n    本地绘制\n    缓存结果"),
                ("pie", .mermaid, "pie title Results\n  \"Ready\" : 8\n  \"Pending\" : 2"),
                ("gantt", .mermaid, "gantt\n  dateFormat YYYY-MM-DD\n  section Work\n  Render :a, 2026-10-26, 1d"),
                ("activity", .plantuml, "@startuml\nstart\n:读取消息;\n:本地绘制;\nstop\n@enduml"),
                ("class", .plantuml, "@startuml\nclass Message\nclass Drawing\nMessage --> Drawing\n@enduml"),
                ("component", .plantuml, "@startuml\n[Client] --> [Renderer]\n@enduml"),
                ("C4", .plantuml, "@startuml\n!include <C4/C4_Container>\nPerson(reader, \"Reader\")\nContainer(client, \"Corral\", \"Native\", \"Reads\")\nRel(reader, client, \"Uses\")\n@enduml")
            ]
            var results: [[String: Any]] = []
            for appearance in [false, true] {
                for (name, kind, source) in matrix {
                    let block = ChatDiagramBlock(kind: kind, source: source, original: source, codeIdentity: nil, progressive: false)
                    let start = ContinuousClock.now
                    let result = await ChatDiagramRenderer.shared.render(host: "media-inspection", block: block, dark: appearance)
                    results.append(["name": name, "kind": kind.rawValue, "dark": appearance,
                                    "rendered": result != nil, "duration": String(describing: start.duration(to: .now))])
                }
            }
            report["matrix"] = results
            let bad = [
                ChatDiagramBlock(kind: .plantuml, source: "@startuml\n!include https://example.com/secret\n@enduml", original: "", codeIdentity: nil, progressive: false),
                ChatDiagramBlock(kind: .mermaid, source: "flowchart invalid !!", original: "", codeIdentity: nil, progressive: false)
            ]
            var rejected = 0
            for block in bad {
                if await ChatDiagramRenderer.shared.render(host: "media-inspection", block: block, dark: false) == nil { rejected += 1 }
            }
            report["rejectedUnsafeOrInvalid"] = rejected
        }
        if let path = ProcessInfo.processInfo.environment["CORRAL_MEDIA_REPORT"],
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("[chat-media] attachments=\(attachments.count) sourceCopy=\(report["sourceCopy"] ?? false)")
    }

    private static func inspectLive(model: AppModel) async {
        for _ in 0..<150 where model.client?.supportsMediaImage != true {
            try? await Task.sleep(for: .milliseconds(200))
        }
        var report: [String: Any] = ["connected": model.client?.supportsMediaImage == true]
        defer { save(report) }
        guard let client = model.client, client.supportsMediaImage,
              let key = ProcessInfo.processInfo.environment["CORRAL_MEDIA_SESSION"] else { return }
        do {
            // The handoff session's cited image sits beyond the newest 20
            // entries; keep the fixture window wide enough to cover it.
            let snapshot = try await client.call(WireProtocol.mSessionMessages, params: ["key": key, "limit": 80], as: SessionMessagesResponse.self)
            let host = model.connectedHostID ?? model.selectedHost?.hostID ?? ""
            let loader = ChatImageLoader(client: client, hostID: host, sessionKey: key)
            let store = ConversationStore(sessionKey: key, client: client, live: true)
            var loaded = 0
            for message in snapshot.messages {
                for reference in ChatImageReference.references(in: message.text) {
                    if case .image = await loader.load(seq: message.seq, ref: reference.ref, tier: loader.inlineTier()) { loaded += 1 }
                }
            }
            // Show the actual cited-image message so the acceptance capture
            // covers the table row path, not only the loader's return value.
            let imageMessage = snapshot.messages.last { !ChatImageReference.references(in: $0.text).isEmpty }
            let visible = imageMessage.map { [$0] } ?? snapshot.messages
            store.applySnapshot(filteredSnapshot(visible, like: snapshot) ?? snapshot)
            report["imagesLoaded"] = loaded
            report["messages"] = snapshot.messages.count
            report["shownImageSeq"] = imageMessage?.seq ?? -1
            let document = MacConversationTextDocument()
            let root = NSHostingView(rootView: ChatView(store: store, runtimeID: "pi")
                .environment(model).environment(\.chatImageLoader, loader)
                .environment(\.macConversationTextDocument, document))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 950, height: 1000),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Corral Chat Media"
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderBack(nil)
            self.window = window
            try? await Task.sleep(for: .seconds(2))
        } catch { report["failed"] = true }
    }

    private static func filteredSnapshot(_ messages: [RichMessage], like base: SessionMessagesResponse) -> SessionMessagesResponse? {
        guard let encoded = try? JSONEncoder().encode(messages),
              let list = try? JSONSerialization.jsonObject(with: encoded) else { return nil }
        let payload: [String: Any] = [
            "messages": list,
            "oldest_seq": messages.map(\.seq).min() ?? 0,
            "newest_seq": messages.map(\.seq).max() ?? 0,
            "version": base.version, "kind": base.kind, "has_more": false,
            "resume": base.resume, "generation": base.generation,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(SessionMessagesResponse.self, from: data)
    }

    private static func save(_ report: [String: Any]) {
        if let path = ProcessInfo.processInfo.environment["CORRAL_MEDIA_REPORT"],
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif
