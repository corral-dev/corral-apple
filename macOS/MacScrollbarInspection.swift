#if DEBUG
import AppKit

/// Read the actual client window without pointer input or preference changes.
enum MacScrollbarInspection {
    static func inspectSidebarIfRequested(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebarSwitches") else { return }
        for _ in 0..<40 where feed.listStore.windowSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for _ in 0..<40 where workspace.layout.revision == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window = NSApp.windows.first(where: { $0.title == "Corral" }),
              let content = window.contentView,
              descendants(content).contains(where: { $0 is NSOutlineView }) else {
            writeSidebarEvidence(["failure": "sidebar outline not mounted",
                                  "windows": NSApp.windows.map(\.title)])
            return
        }
        let keys = workspace.paneKeys, focus = workspace.focusedKey
        let groups = workspace.layout.groups.map { "\($0.id):\($0.members.joined(separator: ","))" }
        defer { workspace.inspectionRestoreWorkspace(keys: keys, focus: focus) }
        var selected: Set<String> = []
        var attempts = 0
        var failure: String?
        // SwiftUI owns List scroller style; a flip here means a contest. The
        // list is rebuilt when its structure changes, so follow each instance.
        let flips = StyleFlips()
        var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
        var markers = 0
        defer { observations.values.forEach { $0.invalidate() } }
        selection: for _ in 0..<3 {
            for row in 1..<18 {
                guard !Task.isCancelled else { return }
                guard let table = descendants(content).compactMap({ $0 as? NSOutlineView }).first,
                      let scroll = table.enclosingScrollView else {
                    failure = "sidebar outline disappeared"
                    break selection
                }
                if observations[ObjectIdentifier(scroll)] == nil {
                    observations[ObjectIdentifier(scroll)] = flips.observe(scroll)
                }
                markers = max(markers, descendants(table).filter { $0 is NativeOverlayScrollerView }.count)
                guard row < table.numberOfRows else { break selection }
                // Public native selection posts the same notification as a
                // sidebar click. No pointer or keyboard input is synthesized.
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                try? await Task.sleep(for: .milliseconds(200))
                guard scroll.window == nil || scroll.scrollerStyle == NSScroller.preferredScrollerStyle else {
                    failure = "sidebar left the system scroller style"
                    break selection
                }
                attempts += 1
                if let key = workspace.focusedKey { selected.insert(key) }
            }
        }
        let evidence: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "attempts": attempts,
            "failure": failure ?? NSNull(),
            "preferredStyle": NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay",
            "distinctSessions": selected.count,
            "sidebarInstances": observations.count,
            "sidebarMarkers": markers,
            "sidebarStyleFlips": flips.count,
            "hostLayoutUnchanged": groups == workspace.layout.groups.map { "\($0.id):\($0.members.joined(separator: ","))" },
        ]
        writeSidebarEvidence(evidence)
    }

    /// AppKit re-sets the same style on preference notices; count real flips.
    private final class StyleFlips {
        var count = 0

        func observe(_ scroll: NSScrollView) -> NSKeyValueObservation {
            var last = scroll.scrollerStyle
            return scroll.observe(\.scrollerStyle, options: []) { [self] scroll, _ in
                MainActor.assumeIsolated {
                    if scroll.scrollerStyle != last { count += 1 }
                    last = scroll.scrollerStyle
                }
            }
        }
    }

    private static func writeSidebarEvidence(_ evidence: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-sidebar-switches.json"), options: .atomic)
        }
    }

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
