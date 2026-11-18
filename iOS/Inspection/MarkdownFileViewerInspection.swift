#if DEBUG && os(iOS)
import SwiftUI

/// Debug-only inspection surface for `MarkdownFileViewer` using a realistic
/// temporary Markdown file so Simulator screenshots verify layout, typography,
/// tables, code blocks, task lists and external links in light/dark mode.
struct MarkdownFileViewerInspection: View {
    private let presentation: ChatFileLoader.MarkdownPresentation

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-inspect-md", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("CORE_PROFILE.md")
        let markdown = """
        # Core Profile

        Owner profile for **Corral** remote workflows. See [Remote Guide](https://example.com/docs) for external references.

        ## Domain Rules

        - Keep native iOS controls (`Button(role: .close)`)
        - [x] Intercept `file://` and relative path links
        - [x] Render Markdown full-screen with source toggle
        - [ ] Secondary file jumps disabled inside preview

        > Remote files are downloaded over the data plane with strict message-level containment.

        ```swift
        struct LoadedChatFile: Identifiable {
            let name: String
            let size: Int
        }
        ```

        | File Type | Viewer | Notes |
        |:---|:---:|---|
        | Markdown | Native | Rendered + Source |
        | PDF / Image | QuickLook | Built-in preview |
        """
        try? Data(markdown.utf8).write(to: fileURL, options: .atomic)
        let loaded = LoadedChatFile(
            id: "inspect-core-profile",
            localURL: fileURL,
            name: "CORE_PROFILE.md",
            displayPath: "~/.config/agents/CORE_PROFILE.md",
            mime: "text/markdown",
            size: markdown.utf8.count,
            sha256: "inspect",
            targetLine: 8
        )
        let link = ChatFileLink(
            ref: fileURL.absoluteString,
            displayName: "CORE_PROFILE.md",
            targetLine: 8,
            isMarkdown: true
        )
        self.presentation = ChatFileLoader.MarkdownPresentation(
            seq: 1,
            link: link,
            phase: .loaded(loaded)
        )
    }

    var body: some View {
        MarkdownFileViewer(
            presentation: presentation,
            hostID: "inspection-host",
            onRetry: {},
            onDismiss: {}
        )
    }
}
#endif
