#if DEBUG
import AppKit

/// Exercises the mounted production sidebar/workspace against the paired host.
/// Never injects input, starts an assistant or drives the user's pointer.
@MainActor
enum MacSearchNavigationInspection {
    static func runIfRequested(workspace: MacWorkspace, model: AppModel,
                               presentSearch: () -> Void, dismissSearch: () -> Void) async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectSearchNavigation"),
              let output = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_NAVIGATION_OUTPUT"] else { return }
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        var results: [String: Bool] = [:]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for _ in 0..<300 {
                if let feed = workspace.feed, model.client != nil,
                   !feed.listStore.windowSessions.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let feed = workspace.feed, let client = model.client else { throw Failure.unready }
            let original = workspace.paneKeys
            let state = workspace.navigation.host
            let history = state.history
            defer { workspace.restorePanes(original); state.history = history }
            let search = state.search
            search.query = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SEARCH"] ?? "透明"
            await search.store.search(search.query, client: client) { model.client === $0 }
            guard let matches = search.store.result?.matches, !matches.isEmpty else { throw Failure.noHistory }
            let originalKeys = Set(feed.listStore.windowSessions.map(\.key))
            guard let hit = matches.first(where: { !originalKeys.contains($0.key) }) else { throw Failure.noHistory }
            let key = hit.key
            let oldMode = workspace.mode(for: key)
            workspace.setMode(.chat, for: key)
            defer { workspace.setMode(oldMode, for: key) }
            search.selection = key
            results["outsideWindow"] = true
            results["searchOpened"] = try await workspace.openSearchResult(key)
            results["sidebarRevealed"] = await waitForSidebar(key, state: state)
            results["noHorizontalOverflow"] = await inspectHorizontalGeometry(key: key, workspace: workspace, folder: folder)
            let reading = prepareReadingPosition(key: key, workspace: workspace)
            await stage("old", results: results, folder: folder, workspace: workspace)

            guard let other = feed.listStore.windowSessions.first(where: {
                $0.key != key && workspace.layout.group(containing: $0.key) == nil
            }) else { throw Failure.noHistory }
            let otherMode = workspace.mode(for: other.key)
            workspace.setMode(.chat, for: other.key)
            defer { workspace.setMode(otherMode, for: other.key) }
            workspace.open(other.key, sessions: feed.listStore.windowSessions, takeKeys: false)
            results["retainedAfterSwitch"] = feed.listStore.windowSessions.contains { $0.key == key }
            await workspace.navigateHistory(by: -1)
            results["back"] = workspace.focusedKey == key
            results["backSidebar"] = await waitForSidebar(key, state: state)
            let returned = conversationScroll(key: key, workspace: workspace)?.coordinator?.navigationPosition
            results["readingPosition"] = reading != nil && reading?.id == returned?.id
                && abs((reading?.offset ?? 0) - (returned?.offset ?? 100)) < 1
            let readingInfo: [String: Any] = reading.map {
                ["id": $0.id ?? "", "offset": $0.offset, "followsLatest": $0.followsLatest]
            } ?? [:]
            let returnedInfo: [String: Any] = returned.map {
                ["id": $0.id ?? "", "offset": $0.offset, "followsLatest": $0.followsLatest]
            } ?? [:]
            try? JSONSerialization.data(withJSONObject: ["prepared": readingInfo, "returned": returnedInfo],
                options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("reading.json"), options: .atomic)
            await stage("back", results: results, folder: folder, workspace: workspace)
            await workspace.navigateHistory(by: 1)
            results["forward"] = workspace.focusedKey == other.key

            let callsResult = search.store.result?.matches.map(\.key)
            search.store.cancelPending()
            search.store.prepare(search.query, client: client)
            results["searchContextRetained"] = search.query != "" && search.selection == key
                && search.store.result?.matches.map(\.key) == callsResult
            results["noRunningWork"] = !search.store.isSearching
            if matches.count > 6 {
                var attached = false
                for _ in 0..<4 {
                    presentSearch()
                    if await waitForSearchScroll(search) { attached = true; break }
                    dismissSearch()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                results["searchScrollAttached"] = attached
                let row = search.inspectScroll(toRow: 6)
                try? await Task.sleep(for: .milliseconds(900))
                results["searchScrollRecorded"] = (row ?? 0) > 0
                try? JSONSerialization.data(withJSONObject: ["row": row ?? -1,
                    "geometry": search.inspectionScrollDiagnostics], options: [.prettyPrinted])
                    .write(to: folder.appendingPathComponent("search-first-geometry.json"), options: .atomic)
                await stage("search", results: results, folder: folder, workspace: workspace)
                dismissSearch()
                try await Task.sleep(for: .milliseconds(500))
                var reattached = false
                for _ in 0..<4 {
                    presentSearch()
                    if await waitForSearchScroll(search) { reattached = true; break }
                    dismissSearch()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                results["searchScrollReattached"] = reattached
                try? await Task.sleep(for: .milliseconds(900))
                var restored: Int?
                for _ in 0..<10 {
                    if let value = search.inspectScroll(toRow: nil) { restored = value; break }
                    if !search.inspectionScrollVisible {
                        dismissSearch()
                        try? await Task.sleep(for: .milliseconds(300))
                        presentSearch()
                        _ = await waitForSearchScroll(search)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                results["searchScrollRestored"] = row != nil && row == restored
                try? JSONSerialization.data(withJSONObject: ["row": restored ?? -1,
                    "recorded": row ?? -1,
                    "geometry": search.inspectionScrollDiagnostics], options: [.prettyPrinted])
                    .write(to: folder.appendingPathComponent("search-restored-geometry.json"), options: .atomic)
                await stage("reopened-search", results: results, folder: folder, workspace: workspace)
                dismissSearch()
            }
            await stage("done", results: results, folder: folder, workspace: workspace)
            try JSONSerialization.data(withJSONObject: ["checks": results,
                "passed": results.values.allSatisfy { $0 }, "sidebar": state.inspectionSidebar,
                "search": ["attached": search.inspectionScrollAttached,
                    "row": search.inspectionScrollRow ?? -1,
                    "clipHeight": search.inspectionScrollClipHeight,
                    "documentHeight": search.inspectionScrollDocumentHeight,
                    "geometry": search.inspectionScrollDiagnostics],
                "events": state.inspectionEvents], options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["passed": false, "error": String(describing: error),
                "checks": results], options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        }
    }

    private static func conversationScroll(key: String, workspace: MacWorkspace) -> MacConversationTable.ConversationScrollView? {
        func find(_ view: NSView) -> MacConversationTable.ConversationScrollView? {
            if let scroll = view as? MacConversationTable.ConversationScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return workspace.paneSurfaces.existingEntry(for: key).flatMap { find($0.view) }
    }

    private static func prepareReadingPosition(key: String, workspace: MacWorkspace) -> (id: String?, offset: CGFloat, followsLatest: Bool)? {
        guard let scroll = conversationScroll(key: key, workspace: workspace),
              let table = scroll.documentView as? NSTableView else { return nil }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.frame.height / 2)))
        scroll.reflectScrolledClipView(scroll.contentView)
        guard let coordinator = scroll.coordinator else { return nil }
        let position = coordinator.navigationPosition
        guard coordinator.restoreNavigationPosition(id: position.id, offset: 17, followsLatest: false) else { return nil }
        return coordinator.navigationPosition
    }

    private static func inspectHorizontalGeometry(key: String, workspace: MacWorkspace, folder: URL) async -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "Corral" }) else { return false }
        let original = window.frame
        defer { window.setFrame(original, display: true) }
        var samples: [[String: Double]] = []
        var skipped: [Double] = []
        for width in [1436.0, 900.0, 1180.0] {
            var frame = original
            frame.size.width = width
            window.setFrame(frame, display: true)
            try? await Task.sleep(for: .milliseconds(400))
            guard let scroll = await waitForConversationScroll(key: key, workspace: workspace),
                  let document = scroll.documentView else { skipped.append(width); continue }
            let clip = scroll.contentView
            let y = clip.bounds.minY
            let proposed = NSRect(x: 60, y: y, width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
            samples.append(["windowWidth": width, "documentWidth": document.frame.width,
                "clipWidth": clip.bounds.width, "x": clip.bounds.minX])
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        try? JSONSerialization.data(withJSONObject: ["samples": samples, "skipped": skipped], options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("horizontal-geometry.json"))
        return samples.count == 3 && samples.allSatisfy { ($0["documentWidth"] ?? 1) <= ($0["clipWidth"] ?? 0) + 0.5 && abs($0["x"] ?? 1) < 0.5 }
    }

    private static func waitForConversationScroll(key: String, workspace: MacWorkspace) async -> MacConversationTable.ConversationScrollView? {
        for _ in 0..<50 {
            if let scroll = conversationScroll(key: key, workspace: workspace), scroll.documentView != nil { return scroll }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func waitForSidebar(_ key: String, state: MacNavigationState.HostState) async -> Bool {
        for _ in 0..<100 {
            if state.inspectionSidebarKey == key, state.inspectionSidebar.values.allSatisfy({ $0 }),
               !state.inspectionSidebar.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func waitForSearchScroll(_ search: MacSearchState) async -> Bool {
        for _ in 0..<200 {
            if search.inspectionScrollAttached, search.inspectionScrollVisible { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func stage(_ phase: String, results: [String: Bool], folder: URL, workspace: MacWorkspace) async {
        let state = workspace.navigation.host
        let report: [String: Any] = ["phase": phase, "checks": results,
            "focus": workspace.focusedKey ?? "", "reveal": state.revealKey ?? "",
            "sidebarKey": state.inspectionSidebarKey ?? "", "sidebar": state.inspectionSidebar,
            "history": state.history.keys, "historyIndex": state.history.index,
            "events": state.inspectionEvents]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("phase.json"), options: .atomic)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
              .write(to: folder.appendingPathComponent("\(phase)-state.json"), options: .atomic)
        func tree(_ view: NSView, depth: Int = 0) -> [String] {
            let info = "\(String(repeating: " ", count: depth))\(type(of: view)) frame=\(view.frame)" + ((view as? NSTableView).map { " rows=\($0.numberOfRows) selected=\($0.selectedRow)" } ?? "")
            return [info] + view.subviews.flatMap { tree($0, depth: depth + 1) }
        }
        let trees = NSApp.windows.compactMap { $0.contentView }.flatMap { tree($0) }
        try? trees.joined(separator: "\n").write(to: folder.appendingPathComponent("\(phase)-views.txt"), atomically: true, encoding: .utf8)
        // App-owned pixels are supplementary geometry evidence, not a desktop capture.
        if let view = NSApp.windows.first(where: { $0.title == "Corral" })?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(phase)-content.png"))
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("continue-\(phase)").path) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private enum Failure: Error { case unready, noHistory }
}
#endif
