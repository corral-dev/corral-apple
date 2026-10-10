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
              let table = descendants(content).compactMap({ $0 as? NSOutlineView }).first else { return }
        let keys = workspace.paneKeys, focus = workspace.focusedKey, board = workspace.showingBoard
        let groups = workspace.layout.groups.map { "\($0.id):\($0.members.joined(separator: ","))" }
        defer { workspace.inspectionRestoreWorkspace(keys: keys, focus: focus, board: board) }
        var selected: Set<String> = []
        var attempts = 0
        for _ in 0..<3 {
            for row in 1..<min(table.numberOfRows, 18) {
                guard !Task.isCancelled else { return }
                // Public native selection posts the same notification as a
                // sidebar click. No pointer or keyboard input is synthesized.
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                try? await Task.sleep(for: .milliseconds(200))
                attempts += 1
                if let key = workspace.focusedKey, !workspace.showingBoard { selected.insert(key) }
            }
        }
        let evidence: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "attempts": attempts,
            "distinctSessions": selected.count,
            "sidebarMarkers": descendants(table).filter { $0 is NativeOverlayScrollerView }.count,
            "hostLayoutUnchanged": groups == workspace.layout.groups.map { "\($0.id):\($0.members.joined(separator: ","))" },
        ]
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
