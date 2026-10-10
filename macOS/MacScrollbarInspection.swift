#if DEBUG
import AppKit

/// Read the actual client window without pointer input or preference changes.
enum MacScrollbarInspection {
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectOverlayScrollers") else { return }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let window = NSApp.windows.first(where: { $0.title == "Corral" }),
                  let content = window.contentView else { continue }
            let markers = descendants(content).compactMap { $0 as? NativeOverlayScrollerView }
            var seen: Set<ObjectIdentifier> = []
            let scrolls = markers.compactMap(\.enclosingScrollView).filter { seen.insert(ObjectIdentifier($0)).inserted }
            guard scrolls.count >= 2 else { continue }
            let evidence: [String: Any] = [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "pid": ProcessInfo.processInfo.processIdentifier,
                "markers": markers.count,
                "scrolls": scrolls.map { scroll in
                    ["style": scroll.scrollerStyle.rawValue,
                     "hasVerticalScroller": scroll.hasVerticalScroller,
                     "nativeDragAction": scroll.verticalScroller?.action != nil,
                     "contentWidth": scroll.contentView.frame.width,
                     "viewportWidth": scroll.bounds.width] as [String: Any]
                },
                "allOverlay": scrolls.allSatisfy { $0.scrollerStyle == .overlay },
                "captureKind": "app-owned-content-export",
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: "/tmp/corral-overlay-inspection.json"), options: .atomic)
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: "/tmp/corral-overlay-content.png"), options: .atomic)
                    }
                }
            } catch {
                NSLog("Corral scrollbar inspection failed: %@", error.localizedDescription)
            }
            return
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
#endif
