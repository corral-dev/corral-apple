#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

@MainActor
final class ChatFileViewerTests: XCTestCase {
    func testMarkdownBubbleLinkInterceptsFileURLButLeavesHTTPSDefault() throws {
        let source = "Read [CORE_PROFILE.md](file:///Users/example/CORE_PROFILE.md#L12) and [Docs](https://example.com)."
        let attributed = ChatMarkdown.attributed(source)
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 2)

        var opened: [ChatFileLink] = []
        let view = SelectableAttributedText(
            attributed: attributed,
            linkHandler: { url in
                guard let link = ChatFileLink.classify(url) else { return nil }
                return { opened.append(link) }
            }
        )

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 240)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()

        guard let textView = findTextView(in: controller.view) else {
            return XCTFail("Expected UITextView in SelectableAttributedText")
        }
        XCTAssertNotNil(textView.delegate)

        let fileURL = try XCTUnwrap(URL(string: "file:///Users/example/CORE_PROFILE.md#L12"))
        let httpsURL = try XCTUnwrap(URL(string: "https://example.com"))

        XCTAssertNotNil(ChatFileLink.classify(fileURL))
        XCTAssertNil(ChatFileLink.classify(httpsURL))
        let handler = view.linkHandler
        handler?(fileURL)?()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.displayName, "CORE_PROFILE.md")
        XCTAssertEqual(opened.first?.targetLine, 12)
        XCTAssertNil(handler?(httpsURL))
    }

    func testMarkdownFileViewerMountsAndRendersDocument() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-md-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("CORE_PROFILE.md")
        let markdown = """
        # Core Profile

        Owner profile for **Corral** remote workflows. See [Remote Guide](https://example.com/docs).

        ## Domain Rules

        - Keep native controls
        - [x] Intercept `file://` links
        - [ ] Disable secondary file jumps

        > Remote files download over the data plane with containment checks.

        ```swift
        struct LoadedChatFile: Identifiable {
            let name: String
            let size: Int
        }
        ```

        | Key | Value |
        |---|---|
        | Mode | Native |
        | Preview | QuickLook |
        """
        try Data(markdown.utf8).write(to: fileURL)

        let loaded = LoadedChatFile(
            id: "test-md",
            localURL: fileURL,
            name: "CORE_PROFILE.md",
            displayPath: "~/.config/agents/CORE_PROFILE.md",
            mime: "text/markdown",
            size: markdown.utf8.count,
            sha256: "abc",
            targetLine: 8
        )
        let link = ChatFileLink(
            ref: fileURL.absoluteString,
            displayName: "CORE_PROFILE.md",
            targetLine: 8,
            isMarkdown: true
        )
        let presentation = ChatFileLoader.MarkdownPresentation(
            seq: 1,
            link: link,
            phase: .loaded(loaded)
        )

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousWindow?.makeKeyAndVisible() }

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let viewer = MarkdownFileViewer(
                presentation: presentation,
                hostID: "test-host",
                onRetry: {},
                onDismiss: {}
            )
            .preferredColorScheme(scheme)

            let controller = UIHostingController(rootView: viewer)
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            // Allow background MarkdownDocument.parse task to complete and update UI.
            try await Task.sleep(for: .milliseconds(500))
            controller.view.layoutIfNeeded()

            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let png = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(png.count, 5_000, "Rendered MarkdownFileViewer (\(name)) should contain visible content")
        }
    }

    func testMarkdownFileViewerMultiLayerPushAndLoaderPop() throws {
        let loader = ChatFileLoader(client: nil, hostID: "h1", sessionKey: "s1")
        let link1 = ChatFileLink(ref: "CORE_PROFILE.md", displayName: "CORE_PROFILE.md", targetLine: nil, isMarkdown: true)
        let link2 = ChatFileLink(ref: "DOMAIN_RULES.md#mobile-preview", displayName: "DOMAIN_RULES.md", targetLine: nil, targetAnchor: "mobile-preview", isMarkdown: true)

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("core.md")
        let layer2URL = FileManager.default.temporaryDirectory.appendingPathComponent("domain.md")
        let rootFile = LoadedChatFile(
            id: "r1",
            localURL: rootURL,
            name: "CORE_PROFILE.md",
            displayPath: "~/CORE_PROFILE.md",
            mime: "text/markdown",
            size: 10,
            sha256: "a",
            targetLine: nil
        )
        let layer2File = LoadedChatFile(
            id: "r2",
            localURL: layer2URL,
            name: "DOMAIN_RULES.md",
            displayPath: "~/DOMAIN_RULES.md",
            mime: "text/markdown",
            size: 20,
            sha256: "b",
            targetLine: nil,
            targetAnchor: "mobile-preview"
        )
        let rootLayer = ChatFileLoader.MarkdownPresentation(seq: 3, via: [], link: link1, phase: .loaded(rootFile))
        let secondLayer = ChatFileLoader.MarkdownPresentation(seq: 3, via: rootLayer.childVia, link: link2, phase: .loaded(layer2File))
        XCTAssertEqual(secondLayer.via, ["CORE_PROFILE.md"])
        XCTAssertEqual(secondLayer.childVia, ["CORE_PROFILE.md", "DOMAIN_RULES.md#mobile-preview"])

        loader.markdownPresentation = rootLayer
        loader.pushedMarkdownLayers = [secondLayer]
        XCTAssertEqual(loader.pushedMarkdownIDs, [secondLayer.id])
        XCTAssertEqual(loader.presentation(for: secondLayer.id)?.link.displayName, "DOMAIN_RULES.md")

        // Simulated native NavigationStack pop removes the trailing layer cleanly.
        loader.pushedMarkdownIDs = []
        XCTAssertTrue(loader.pushedMarkdownLayers.isEmpty)
        XCTAssertNotNil(loader.markdownPresentation)

        loader.dismissMarkdown()
        XCTAssertNil(loader.markdownPresentation)
        XCTAssertNil(loader.viewerQuickLookURL)
    }

    private func findTextView(in root: UIView) -> UITextView? {
        if let tv = root as? UITextView { return tv }
        for subview in root.subviews {
            if let hit = findTextView(in: subview) { return hit }
        }
        return nil
    }
}
#endif
