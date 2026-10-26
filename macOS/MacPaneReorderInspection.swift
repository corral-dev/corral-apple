#if DEBUG
import AppKit
import Foundation

/// Header-drag acceptance on the real window. Mouse events are delivered to
/// the header's own view inside this process; the system pointer never moves.
/// It never activates the app or moves the pointer. Gesture and model-driven
/// visual evidence stay separate; the launch flag suppresses layout writes
/// and the original local workspace is restored afterwards.
@MainActor
enum MacPaneReorderInspection {
    private static var claimed = false
    private static var eventNumber = 0

    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard !claimed else { return }
        claimed = true
        let original = (workspace.paneKeys, workspace.focusedKey, workspace.promptsOpen)
        defer {
            workspace.inspectionRestoreWorkspace(keys: original.0, focus: original.1)
            workspace.promptsOpen = original.2
        }
        var report: [String: Any] = ["hostWrites": false, "systemPointerMoved": false]
        do {
            let grouped = Dictionary(grouping: feed.listStore.windowSessions, by: \.cwd)
            guard let candidates = grouped.values.filter({ $0.count >= 4 })
                .max(by: { $0.count < $1.count }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let keys = Array(candidates.prefix(4).map(\.key))
            workspace.inspectionRestoreWorkspace(keys: keys, focus: keys[2])
            for key in keys {
                workspace.setMode(.chat, for: key)
                workspace.promptsOpen[key] = false
            }
            for _ in 0..<100 {
                if keys.allSatisfy({ workspace.paneSurfaces.existingEntry(for: $0)?.view != nil }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" }),
                  let content = window.contentView else { throw CocoaError(.coderValueNotFound) }
            let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
            let screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
            let identities = keys.compactMap { workspace.paneSurfaces.existingEntry(for: $0)?.view }
            guard identities.count == 4 else { throw CocoaError(.coderValueNotFound) }
            report["before"] = keys
            report["screenLocked"] = screenLocked
            report["appActive"] = NSApp.isActive
            report["windowKey"] = window.isKeyWindow
            report["splitWidth"] = workspace.splitWidth
            report["handlePoints"] = keys.map { NSStringFromPoint(point($0, .blank, workspace, content: content)) }
            let handleHeights = keys.compactMap { MacPaneReorderHandles.views[$0]?.bounds.height }
            report["handleHeights"] = handleHeights
            report["compactHeaders"] = handleHeights.count == keys.count
                && handleHeights.allSatisfy { abs($0 - 40 * workspace.interfaceScale) < 1 }
            var seenEvents = 0
            let monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                seenEvents += 1
                return event
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            report["captureBefore"] = await capture("before")

            // 1. Fourth pane, blank header space, over the second pane: insertion.
            var midCaptured = false
            MacPaneReorderProbe.reset()
            let gestureStarted = await drag(keys[3], grip: .blank, toPaneCentre: keys[1],
                                            window: window, content: content, workspace: workspace) { step in
                guard step == 12, !midCaptured else { return }
                midCaptured = true
                report["midDrag"] = ["order": workspace.paneKeys,
                                     "lifted": workspace.liftedPane ?? "",
                                     "offset": workspace.paneReorder?.offset ?? 0,
                                     "probeChanged": MacPaneReorderProbe.changed]
                report["captureMid"] = await capture("mid")
            }
            report["gestureStarted"] = gestureStarted
            report["gestureProbe"] = ["started": MacPaneReorderProbe.started,
                                      "changed": MacPaneReorderProbe.changed,
                                      "ended": MacPaneReorderProbe.ended,
                                      "lastWindowX": MacPaneReorderProbe.lastWindowX ?? -1,
                                      "lastTravel": MacPaneReorderProbe.lastTravel ?? -1]
            report["eventsSeen"] = seenEvents
            try await Task.sleep(for: .seconds(1))
            let expected = [keys[0], keys[3], keys[1], keys[2]]
            report["after"] = workspace.paneKeys
            report["orderCorrect"] = workspace.paneKeys == expected
            report["focusPreserved"] = workspace.focusedKey == keys[2]
            report["settled"] = workspace.paneReorder == nil && workspace.liftedPane == nil
                && workspace.paneShifts.isEmpty
            report["nativeHostsPreserved"] = zip(keys, identities).allSatisfy {
                workspace.paneSurfaces.existingEntry(for: $0.0)?.view === $0.1
            }
            report["captureAfter"] = await capture("after")

            if gestureStarted {
                // 2. The same pane by its title, far past the trailing edge: last slot.
                var maxLeading: CGFloat = 0
                _ = await drag(keys[3], grip: .title, toWindowX: content.bounds.maxX + 400, window: window,
                               content: content, workspace: workspace) { _ in
                    guard let drag = workspace.paneReorder,
                          let slot = workspace.paneKeys.firstIndex(of: drag.key) else { return }
                    let geometry = MacPaneDragGeometry(width: workspace.splitWidth, count: workspace.paneKeys.count)
                    maxLeading = max(maxLeading, geometry.slotX(slot) + drag.offset)
                }
                try await Task.sleep(for: .seconds(1))
                let geometry = MacPaneDragGeometry(width: workspace.splitWidth, count: 4)
                report["titleDragToEnd"] = workspace.paneKeys == keys
                report["edgeClamped"] = maxLeading <= geometry.slotX(3) + 0.5

                // 3. Less than half a pane: the order stays.
                let slot = MacPaneDragGeometry(width: workspace.splitWidth, count: 4).slotWidth
                _ = await drag(keys[0], grip: .blank,
                               toWindowX: point(keys[0], .blank, workspace, content: content).x + slot * 0.3,
                               window: window, content: content, workspace: workspace) { _ in }
                try await Task.sleep(for: .seconds(1))
                report["shortDragKeepsOrder"] = workspace.paneKeys == keys

                // 4. A click without travel on the title is a click, not a drag.
                let click = point(keys[0], .title, workspace, content: content)
                deliver([(.leftMouseDown, click), (.leftMouseUp, click)], window: window, content: content)
                try await Task.sleep(for: .milliseconds(400))
                report["clickKeepsOrder"] = workspace.paneKeys == keys && workspace.paneReorder == nil
                report["clickFocusesPane"] = workspace.focusedKey == keys[0]
            } else {
                // The console session delivered no mouse input to any app view
                // (locked screen). Drive the same workspace entry points to
                // capture the real window's lifted pane, live reflow and release;
                // the gesture entry itself stays unverified.
                report["modelDriven"] = true
                workspace.focus(keys[2])
                try? await Task.sleep(for: .milliseconds(100))
                let travel = point(keys[1], .blank, workspace, content: content).x
                    - point(keys[3], .blank, workspace, content: content).x
                workspace.beginPaneDrag(keys[3])
                for step in 1...16 {
                    workspace.dragPane(keys[3], travel: travel * CGFloat(step) / 16)
                    try? await Task.sleep(for: .milliseconds(20))
                    guard step == 10 else { continue }
                    report["midDrag"] = ["order": workspace.paneKeys,
                                         "lifted": workspace.liftedPane ?? "",
                                         "offset": workspace.paneReorder?.offset ?? 0]
                    report["captureMid"] = await capture("mid")
                }
                workspace.endPaneDrag(keys[3])
                try await Task.sleep(for: .seconds(1))
                report["after"] = workspace.paneKeys
                report["orderCorrect"] = workspace.paneKeys == expected
                report["focusPreserved"] = workspace.focusedKey == keys[2]
                report["settled"] = workspace.paneReorder == nil && workspace.liftedPane == nil
                    && workspace.paneShifts.isEmpty
                report["nativeHostsPreserved"] = zip(keys, identities).allSatisfy {
                    workspace.paneSurfaces.existingEntry(for: $0.0)?.view === $0.1
                }
                report["captureAfter"] = await capture("after")
            }
            report["gestureAcceptancePassed"] = gestureStarted
                && report["orderCorrect"] as? Bool == true
                && report["titleDragToEnd"] as? Bool == true
                && report["shortDragKeepsOrder"] as? Bool == true
                && report["clickFocusesPane"] as? Bool == true
            if screenLocked { report["gestureStatus"] = "blockedByScreenLock" }
            else if report["gestureAcceptancePassed"] as? Bool == true { report["gestureStatus"] = "passed" }
            else { report["gestureStatus"] = NSApp.isActive ? "failed" : "inactiveWindow" }

            // Exercise the production immediate-release reset on mounted
            // panes too; this is motion evidence, separate from input routing.
            workspace.inspectionRestoreWorkspace(keys: keys, focus: keys[2])
            workspace.beginPaneDrag(keys[0])
            workspace.dragPane(keys[0], travel: workspace.splitWidth / 4)
            workspace.endPaneDrag(keys[0])
            try await Task.sleep(for: .milliseconds(400))
            report["immediateReleaseSettled"] = workspace.paneKeys == [keys[1], keys[0], keys[2], keys[3]]
                && workspace.paneShifts.isEmpty && workspace.paneReorder == nil && workspace.liftedPane == nil
            report["captureImmediateRelease"] = await capture("fast-release")
        } catch {
            report["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pane-reorder-inspection.json"), options: .atomic)
        }
    }

    private enum Grip { case title, blank }

    /// Window base coordinates of a press point on a pane's real handle. The
    /// handle supplies both axes directly, without mixing SwiftUI global
    /// coordinates with AppKit window coordinates.
    private static func point(_ key: String, _ grip: Grip, _ workspace: MacWorkspace,
                              content: NSView) -> CGPoint {
        guard let handle = MacPaneReorderHandles.views[key], handle.window != nil else { return .zero }
        let frame = handle.convert(handle.bounds, to: nil)
        let x = grip == .title ? frame.minX + 24 : frame.maxX - 12
        return CGPoint(x: x, y: frame.midY)
    }

    private static func drag(_ key: String, grip: Grip, toPaneCentre target: String, window: NSWindow,
                             content: NSView, workspace: MacWorkspace,
                             during: (Int) async -> Void) async -> Bool {
        // The same press point on the target pane's handle: the dragged pane
        // then sits exactly over the target slot.
        let travel = point(target, grip, workspace, content: content).x
            - point(key, grip, workspace, content: content).x
        return await drag(key, grip: grip,
                          toWindowX: point(key, grip, workspace, content: content).x + travel,
                          window: window, content: content, workspace: workspace, during: during)
    }

    private static func drag(_ key: String, grip: Grip, toWindowX endX: CGFloat, window: NSWindow,
                             content: NSView, workspace: MacWorkspace,
                             during: (Int) async -> Void) async -> Bool {
        let start = point(key, grip, workspace, content: content)
        guard hitView(start, window: window, content: content) != nil else { return false }
        var started = false
        post(.leftMouseDown, start, window: window, content: content)
        try? await Task.sleep(for: .milliseconds(16))
        let steps = 24
        for step in 1...steps {
            let x = start.x + (endX - start.x) * CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: x, y: start.y), window: window, content: content)
            try? await Task.sleep(for: .milliseconds(24))
            started = started || workspace.paneReorder?.key == key
            await during(step)
        }
        post(.leftMouseUp, CGPoint(x: endX, y: start.y), window: window, content: content)
        try? await Task.sleep(for: .milliseconds(16))
        return started
    }

    private static func deliver(_ events: [(NSEvent.EventType, CGPoint)], window: NSWindow, content: NSView) {
        guard let first = events.first, hitView(first.1, window: window, content: content) != nil else { return }
        for (type, point) in events {
            post(type, point, window: window, content: content)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    /// Appends to the real application queue; the running run loop delivers
    /// synthetic events through AppKit without moving the system pointer.
    private static func post(_ type: NSEvent.EventType, _ point: CGPoint, window: NSWindow, content: NSView) {
        NSApp.postEvent(event(type, point, window: window, content: content), atStart: false)
    }

    private static func hitView(_ point: CGPoint, window: NSWindow, content: NSView) -> NSView? {
        content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }

    private static func event(_ type: NSEvent.EventType, _ point: CGPoint, window: NSWindow,
                              content: NSView) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: point,
                                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                  clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Invoke the required window-capture skill, never a private view snapshot.
    private static func capture(_ stage: String) async -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let tool = env["CORRAL_INSPECTION_REORDER_CAPTURE_TOOL"],
              let python = env["CORRAL_INSPECTION_REORDER_PYTHON"],
              let window = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [tool, "capture", "--wake", "--window-id", String(window.windowNumber),
                             "--json", "-o", "/tmp/corral-pane-reorder-\(stage).png"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
#endif
