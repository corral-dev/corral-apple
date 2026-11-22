#if DEBUG && os(iOS)
import SwiftUI

/// Debug-only inspection surface for `MarkdownFileViewer` using linked
/// temporary Markdown files so Simulator screenshots verify layout, typography,
/// tables, code blocks, task lists, outline navigation, and multi-layer jumps
/// in light/dark mode.
struct MarkdownFileViewerInspection: View {
    private let presentation: ChatFileLoader.MarkdownPresentation
    private let filesByRef: [String: LoadedChatFile]

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-inspect-md", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rootURL = dir.appendingPathComponent("CORE_PROFILE.md")
        let domainURL = dir.appendingPathComponent("DOMAIN_RULES.md")

        let rootMarkdown = """
        # Core Profile

        Owner profile for **Corral** remote workflows. See [Remote Guide](https://example.com/docs) for external references or open [Domain Rules](DOMAIN_RULES.md#L5) in Layer 2.

        ## Domain Rules

        - Keep native iOS controls (`Button(role: .close)`)
        - [x] Intercept `file://` and relative path links
        - [x] Support multi-layer document navigation with back stack
        - [ ] Inline image previews inside local folders

        > Remote files are downloaded over the data plane with hop-chain containment checks.

        ```swift
        struct LoadedChatFile: Identifiable {
            let name: String
            let size: Int
        }
        ```

        | File Type | Viewer | Notes |
        |:---|:---:|---|
        | Markdown | Native | Rendered + Source + Outline |
        | PDF / Image | QuickLook | In-viewer preview |
        """

        let domainMarkdown = """
        # Domain Rules

        Layered documentation loaded relative to `CORE_PROFILE.md`.

        ## Mobile Preview Rules

        1. Keep the document filename visible in the navigation bar
        2. Push nested Markdown files with native `< Back` navigation
        3. Jump back to [Core Profile](CORE_PROFILE.md#domain-rules) at any time

        > Multi-layer hops resolve relative paths from the parent file's directory.
        """

        try? Data(rootMarkdown.utf8).write(to: rootURL, options: .atomic)
        try? Data(domainMarkdown.utf8).write(to: domainURL, options: .atomic)

        let rootLoaded = LoadedChatFile(
            id: "inspect-core-profile",
            localURL: rootURL,
            name: "CORE_PROFILE.md",
            displayPath: "~/.config/agents/CORE_PROFILE.md",
            mime: "text/markdown",
            size: rootMarkdown.utf8.count,
            sha256: "inspect-root",
            targetLine: 8
        )
        let domainLoaded = LoadedChatFile(
            id: "inspect-domain-rules",
            localURL: domainURL,
            name: "DOMAIN_RULES.md",
            displayPath: "~/.config/agents/DOMAIN_RULES.md",
            mime: "text/markdown",
            size: domainMarkdown.utf8.count,
            sha256: "inspect-domain",
            targetLine: 5
        )
        let link = ChatFileLink(
            ref: rootURL.absoluteString,
            displayName: "CORE_PROFILE.md",
            targetLine: 8,
            isMarkdown: true
        )
        self.presentation = ChatFileLoader.MarkdownPresentation(
            seq: 1,
            link: link,
            phase: .loaded(rootLoaded)
        )
        self.filesByRef = [
            "DOMAIN_RULES.md": domainLoaded,
            "CORE_PROFILE.md": rootLoaded,
        ]
    }

    var body: some View {
        MarkdownFileViewer(
            presentation: presentation,
            hostID: "inspection-host",
            onRetry: {},
            onDismiss: {},
            onOpenLocalLink: { via, link in
                let stripped = link.ref.split(separator: "#").first.map(String.init) ?? link.ref
                guard let target = filesByRef[stripped] ?? filesByRef[link.displayName] else {
                    return nil
                }
                let updated = LoadedChatFile(
                    id: "\(target.id)|\(via.count)|\(link.targetLine ?? 0)|\(link.targetAnchor ?? "")",
                    localURL: target.localURL,
                    name: target.name,
                    displayPath: target.displayPath,
                    mime: target.mime,
                    size: target.size,
                    sha256: target.sha256,
                    targetLine: link.targetLine,
                    targetAnchor: link.targetAnchor
                )
                return ChatFileLoader.MarkdownPresentation(
                    seq: 1,
                    via: via,
                    link: link,
                    phase: .loaded(updated)
                )
            }
        )
    }
}
#endif
