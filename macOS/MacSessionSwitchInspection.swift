#if DEBUG
import AppKit
import Foundation

/// Runs the sidebar's workspace action on read-only ended sessions. It does
/// not drive the pointer, change groups, send input or publish conversation text.
@MainActor
enum MacSessionSwitchInspection {
    static var stores: [String: ConversationStore] = [:]
    static var preparationMs: [String: Double] = [:]
    private static var claimed = false

    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-CorralInspectSessionSwitch")
    }

    /// Skip the forced full-subtree layout/draw: measures the window's natural
    /// next-frame work for visible rows only (user-perceived), not the worst
    /// case of realizing every retained row.
    static var noForce: Bool {
        ProcessInfo.processInfo.arguments.contains("-CorralInspectSessionSwitchNoForce")
    }

    static func run(feed: HostSessionFeed, workspace: MacWorkspace, zoom: MacInterfaceZoom) async {
        guard enabled, !claimed else { return }
        claimed = true
        for _ in 0..<100 where workspace.layout.revision == 0 || feed.listStore.windowSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let original = (workspace.paneKeys, workspace.focusedKey)
        let rendering = ProcessInfo.processInfo.arguments.contains("-CorralInspectRendering")
        let originalZoom = zoom.percentage
        let window = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible })
        let originalSize = window?.contentView?.bounds.size
        defer {
            if rendering {
                zoom.setPercentage(originalZoom)
                if let originalSize { window?.setContentSize(originalSize) }
            }
        }
        let sessions = feed.listStore.windowSessions
        let candidates = Array(sessions.filter {
            !$0.live && !$0.hosted && $0.attention == .none
                && workspace.layout.group(containing: $0.key) == nil
                && workspace.mode(for: $0.key) == .chat
        }.prefix(8))
        var measurements: [[String: Any]] = []
        for count in [1, 2, 4] where candidates.count >= count * 2 {
          for cycle in 0..<4 {
            for index in 0..<2 {
                let chosen = Array(candidates.dropFirst(index * count).prefix(count))
                guard let session = chosen.first else { continue }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                for session in chosen {
                    stores[session.key] = nil
                    preparationMs[session.key] = nil
                }
                ConversationStore.resetSwitchCounters()
                MacTextRowSwitchCounters.reset()
                SwitchBodyCounters.reset()
                let clock = ContinuousClock()
                let started = clock.now
                let stall = MainThreadStallProbe()
                stall.begin()
                if count == 1 {
                    workspace.open(session.key, sessions: sessions, takeKeys: false)
                } else {
                    // The same split presentation mutation without writing a
                    // temporary group into the host or the user's TUI.
                    workspace.inspectionRestoreWorkspace(keys: chosen.map(\.key), focus: session.key)
                }
                let selectionMs = milliseconds(started.duration(to: clock.now))
                var visible = false
                var firstVisibleMs = -1.0
                for _ in 0..<2000 {
                    if chosen.allSatisfy({ session in
                        let store = workspace.paneSurfaces.store(for: session.key) ?? stores[session.key]
                        return store?.timelineItems.isEmpty == false
                            && (workspace.paneFrames[session.key] != nil || workspace.paneSurfaces.isMounted(session.key))
                    }),
                       let content = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible })?.contentView {
                        // First paint gate (user-perceived): state is ready and the
                        // window will draw visible rows on its next frame. The
                        // forced full layout below measures the worst case, not
                        // what the next display link actually draws.
                        firstVisibleMs = milliseconds(started.duration(to: clock.now))
                        if !noForce {
                            content.layoutSubtreeIfNeeded()
                            content.displayIfNeeded()
                        }
                        visible = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                let displayMs = milliseconds(started.duration(to: clock.now))
                try? await Task.sleep(for: .milliseconds(200))
                var record = stall.end()
                if rendering {
                    zoom.setPercentage([100, 150, 80, 120][cycle])
                    if let window, let originalSize {
                        window.setContentSize(NSSize(width: max(1100, originalSize.width * (index == 0 ? 1 : 0.8)),
                                                     height: originalSize.height))
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                    record["rendering"] = chosen.map { session in
                        renderGeometry(workspace.paneSurfaces.existingEntry(for: session.key)?.view,
                                       store: workspace.paneSurfaces.store(for: session.key))
                    }
                    try? await Task.sleep(for: .milliseconds(650))
                    let settled = chosen.map { session in
                        renderGeometry(workspace.paneSurfaces.existingEntry(for: session.key)?.view,
                                       store: workspace.paneSurfaces.store(for: session.key))
                    }
                    record["settledRendering"] = settled
                    if ProcessInfo.processInfo.arguments.contains("-CorralInspectFastScroll") {
                        var sweeps: [[String: Any]] = []
                        for (pane, session) in chosen.enumerated() {
                            sweeps.append(await fastScroll(
                                workspace.paneSurfaces.existingEntry(for: session.key)?.view,
                                store: workspace.paneSurfaces.store(for: session.key),
                                label: "\(count)-\(cycle)-\(index)-\(pane)"
                            ))
                        }
                        record["fastScroll"] = sweeps
                    }
                    // Hold a suspicious sample on screen so an external window
                    // capture can confirm what actually drew there.
                    let snapshots = ProcessInfo.processInfo.arguments.contains("-CorralInspectRenderingSnapshots")
                    if snapshots || (ProcessInfo.processInfo.arguments.contains("-CorralInspectRenderingHold")
                                     && settled.contains(where: { $0["blank"] as? Bool ?? true })) {
                        let marker: [String: Any] = ["panes": count, "cycle": cycle, "sessionIndex": index, "at": Date().timeIntervalSince1970]
                        if let data = try? JSONSerialization.data(withJSONObject: marker) {
                            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-render-hold.json"), options: .atomic)
                        }
                        for (pane, session) in chosen.enumerated() {
                            guard let view = workspace.paneSurfaces.existingEntry(for: session.key)?.view,
                                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(
                                fileURLWithPath: "/tmp/corral-render-hold-\(count)-\(cycle)-\(index)-\(pane).png"))
                        }
                        if !snapshots { try? await Task.sleep(for: .seconds(4)) }
                    }
                }
                record["cycle"] = cycle
                record["sessionIndex"] = index
                record["panes"] = count
                record["selectionMs"] = selectionMs
                record["firstVisibleMs"] = firstVisibleMs
                record["displayMs"] = displayMs
                record["preparationMs"] = preparationMs[session.key] ?? -1
                record["messages"] = chosen.reduce(0) {
                    $0 + ((workspace.paneSurfaces.store(for: $1.key) ?? stores[$1.key])?.messages.count ?? 0)
                }
                record["timelineTail"] = chosen.map { session in
                    let store = workspace.paneSurfaces.store(for: session.key) ?? stores[session.key]
                    return store?.timelineItems.suffix(8).map { item -> [String: Any] in
                        switch item {
                        case .message(let message):
                            return ["kind": "message", "characters": message.text?.count ?? 0]
                        case .toolGroup(_, _, let tools):
                            return ["kind": "tools", "count": tools.count]
                        }
                    } ?? []
                }
                record["visible"] = visible
                record["rowMakes"] = MacTextRowSwitchCounters.makes
                record["rowDismantles"] = MacTextRowSwitchCounters.dismantles
                record["rowTextSets"] = MacTextRowSwitchCounters.textSets
                record["docEarlyReturns"] = MacTextRowSwitchCounters.docEarlyReturns
                record["docRenders"] = MacTextRowSwitchCounters.docRenders
                record["timelineRebuilds"] = ConversationStore.timelineRebuilds
                record["timelineSkips"] = ConversationStore.timelineSkips
                record["promptsHits"] = ConversationStore.promptsHits
                record["promptsRecomputes"] = ConversationStore.promptsRecomputes
                record["bubbleBodies"] = SwitchBodyCounters.bubbleBodies
                record["toolBodies"] = SwitchBodyCounters.toolBodies
                measurements.append(record)
                save(measurements)
                for session in chosen { stores[session.key] = nil }
            }
          }
        }
        workspace.inspectionRestoreWorkspace(keys: original.0, focus: original.1)
        save(measurements)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Fast trackpad flicks delivered to the pane's own scroll view (no
    /// pointer movement): up through the loaded history and back down. Each
    /// step samples the next frame; blank or overlapping steps are snapshotted.
    private static func fastScroll(_ root: NSView?, store: ConversationStore?, label: String) async -> [String: Any] {
        guard let root else { return ["missingPane": true] }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let scroll = descendants(root).compactMap({ $0 as? NSScrollView })
            .max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }),
              let document = scroll.documentView,
              document.bounds.height > scroll.contentView.bounds.height * 1.5 else { return ["short": true] }
        func wheel(_ delta: Int32, phase: Int64) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: delta, wheel2: 0, wheel3: 0) else { return }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
            if let window = scroll.window {
                let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                let screen = window.convertPoint(toScreen: center)
                // Quartz event locations use a top-left origin on the main display.
                event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            }
            // Routed through the window like a real trackpad event, so the
            // view under the pane centre (not the pointer) receives it.
            if let ns = NSEvent(cgEvent: event) { scroll.window?.sendEvent(ns) }
        }
        var hitView = "none"
        if let window = scroll.window, let content = window.contentView {
            let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
            hitView = content.hitTest(content.convert(center, from: nil)).map { String(describing: type(of: $0)) } ?? "nil"
        }
        var steps = 0
        var bad: [[String: Any]] = []
        var snapshots = 0
        var origins: [Double] = []
        let useWheel = ProcessInfo.processInfo.arguments.contains("-CorralInspectFastScrollWheel")
        for direction: Int32 in [1, -1] {
            for _ in 0..<40 {
                if useWheel {
                    wheel(direction * 260, phase: 0)
                } else {
                    // A fast scroller-knob drag: the clip moves 260 pt per frame.
                    let clip = scroll.contentView
                    let target = NSRect(origin: NSPoint(x: clip.bounds.minX,
                                                        y: clip.bounds.minY - CGFloat(direction) * 260),
                                        size: clip.bounds.size)
                    clip.scroll(to: clip.constrainBoundsRect(target).origin)
                    scroll.reflectScrolledClipView(clip)
                }
                try? await Task.sleep(for: .milliseconds(12))
                steps += 1
                origins.append(scroll.contentView.bounds.minY)
                let sample = renderGeometry(root, store: store)
                let failed = sample["blank"] as? Bool ?? true
                    || ["overflowRows", "emptyGlyphRows", "wrongMessageRanges", "overlappingRows"]
                        .contains { (sample[$0] as? Int ?? 0) > 0 }
                guard failed else { continue }
                var entry = sample
                entry.removeValue(forKey: "allTextFrames")
                entry["step"] = steps
                bad.append(entry)
                if snapshots < 3, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    snapshots += 1
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(
                        fileURLWithPath: "/tmp/corral-fastscroll-\(label)-\(steps).png"))
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            let settled = renderGeometry(root, store: store)
            if settled["blank"] as? Bool ?? true
                || ["overflowRows", "emptyGlyphRows", "wrongMessageRanges", "overlappingRows"]
                    .contains(where: { (settled[$0] as? Int ?? 0) > 0 }) {
                var entry = settled
                entry["step"] = "settled-\(direction)"
                bad.append(entry)
            }
        }
        return ["hitView": hitView, "steps": steps, "bad": bad, "originRange": [origins.min() ?? 0, origins.max() ?? 0],
                "document": document.bounds.height]
    }

    /// Inspect only product-owned native views. Never force layout or scroll:
    /// doing either before observing can repair the blank viewport under test.
    static func renderGeometry(_ root: NSView?, store: ConversationStore?) -> [String: Any] {
        guard let root else { return ["missingPane": true] }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let texts = descendants(root).compactMap { $0 as? MacDirectMessageTextView }
            .filter { !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor }
        var overflows = 0
        var emptyGlyphRows = 0
        var rangesWrong = 0
        var overflowDetails: [[String: Double]] = []
        for text in texts {
            guard let layout = text.layoutManager, let container = text.textContainer else { continue }
            let used = layout.usedRect(for: container)
            if used.maxY > text.bounds.height + 1 {
                overflows += 1
                let glyphBounds = layout.boundingRect(forGlyphRange: layout.glyphRange(for: container), in: container)
                let characters = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
                let font = (text.textStorage?.length ?? 0) > characters.location
                    ? (text.textStorage?.attribute(.font, at: characters.location, effectiveRange: nil) as? NSFont)?.pointSize ?? -1 : -1
                overflowDetails.append(["usedHeight": used.maxY, "rowHeight": text.bounds.height,
                                        "glyphHeight": glyphBounds.maxY, "width": text.bounds.width,
                                        "containerWidth": container.size.width, "characters": Double(characters.length),
                                        "fontSize": Double(font), "superHeight": text.superview?.bounds.height ?? -1,
                                        "hostHeight": text.superview?.superview?.bounds.height ?? -1])
            }
            // A sliver between lines (or only padding) legitimately has no glyphs.
            if text.visibleRect.height > 24,
               layout.glyphRange(forBoundingRect: text.visibleRect, in: container).length == 0 { emptyGlyphRows += 1 }
            if let document = layout.delegate as? MacConversationTextDocument, let expected = document.range(of: text) {
                let actual = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
                if actual.location != expected.location || actual.length < expected.length { rangesWrong += 1 }
            }
        }
        let frames = texts.map { $0.convert($0.bounds, to: root) }.sorted { $0.minY < $1.minY }
        let overlaps = zip(frames, frames.dropFirst()).filter { $0.0.maxY > $0.1.minY + 1 }.count
        let scrolls = descendants(root).compactMap { $0 as? NSScrollView }.map {
            ["visible": NSStringFromRect($0.documentVisibleRect),
             "document": NSStringFromRect($0.documentView?.bounds ?? .zero)]
        }
        let swiftUI = store.flatMap { MacChatScrollGeometryProbe.latest[ObjectIdentifier($0)] } ?? [:]
        // Question cards, tool summaries and the activity cue are content
        // without native text views: a viewport showing only them is not blank.
        let nonTextIDs = (swiftUI["visibleIDs"] as? [String] ?? []).filter { !$0.hasPrefix("message-") }
        let docFrames = texts.compactMap { text -> String? in
            guard let document = text.enclosingScrollView?.documentView,
                  let layout = text.layoutManager, let container = text.textContainer else { return nil }
            let frame = text.convert(text.bounds, to: document)
            return "y=\(frame.minY)..\(frame.maxY) used=\(layout.usedRect(for: container).maxY) doc=\(document.bounds.height)"
        }
        let tables = descendants(root).compactMap { $0 as? NSTableView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        return ["tableIDs": tables.map { String(describing: ObjectIdentifier($0)) },
                "tableRows": tables.map { $0.numberOfRows },
                "docFrames": docFrames, "blank": texts.isEmpty && nonTextIDs.isEmpty,
                "swiftUIScroll": swiftUI, "visibleTextRows": texts.count, "overflowRows": overflows, "emptyGlyphRows": emptyGlyphRows,
                "wrongMessageRanges": rangesWrong, "overlappingRows": overlaps, "overflowDetails": overflowDetails,
                "scrolls": scrolls, "allTextFrames": descendants(root).compactMap { $0 as? MacDirectMessageTextView }.map {
                    NSStringFromRect($0.convert($0.bounds, to: root))
                }]
    }

    private static func save(_ measurements: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-session-switch.json"), options: .atomic)
    }
}
#endif
