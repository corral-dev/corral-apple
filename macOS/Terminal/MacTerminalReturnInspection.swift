#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Exercises the real Mac pane presentation with a running, hosted agent.
/// Uses in-memory workspace changes and never sends terminal input.
@MainActor
enum MacTerminalReturnInspection {
    private static var started = false
    private static var coldStarted = false

    static func runIfRequested(workspace: MacWorkspace, session: SessionSummary,
                               stream: RemoteTerminalStream) {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalReturn"),
              !started, session.hosted, session.live else { return }
        started = true
        Task { await run(workspace: workspace, session: session, stream: stream) }
    }

    private static func run(workspace: MacWorkspace, session: SessionSummary,
                            stream: RemoteTerminalStream) async {
        let clock = ContinuousClock()
        let originalKeys = workspace.paneKeys
        let originalFocus = workspace.focusedKey
        let originalMode = workspace.mode(for: session.key)
        defer {
            workspace.setMode(originalMode, for: session.key)
            workspace.inspectionRestoreWorkspace(keys: originalKeys, focus: originalFocus)
        }

        var host: TerminalHostView?
        for _ in 0..<150 {
            if stream.phase == .live,
               let latest = TerminalHostView.inspectionLatest, latest.stream === stream,
               latest.inspectionVisibleText.contains(where: { !$0.isEmpty }) {
                host = latest
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let host else {
            write(["error": "running terminal did not deliver an initial screen"])
            return
        }
        let profiling = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalReturnProfile")
        if profiling { try? await Task.sleep(for: .seconds(5)) }
        let split = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalReturnSplit")
        let modeOnly = split || ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalReturnModeOnly")
        // Owner's scenario: the terminal beside three other panes in one split.
        var splitKeys: [String] = []
        if split {
            let peers = workspace.feed?.listStore.windowSessions
                .filter { $0.key != session.key && !$0.hosted && !$0.live }.prefix(3).map(\.key) ?? []
            splitKeys = [session.key] + peers
            workspace.inspectionRestoreWorkspace(keys: splitKeys, focus: session.key)
            try? await Task.sleep(for: .seconds(2))
        }

        workspace.setMode(.chat, for: session.key)
        _ = await waitUntil { !isVisible(host) }
        let hiddenAfterChat = !isVisible(host)
        let modeStall = MainThreadStallProbe()
        modeStall.begin()
        let modeStart = clock.now
        workspace.setMode(.terminal, for: session.key)
        let modeMutationMs = milliseconds(modeStart.duration(to: clock.now))
        let modeReturned = await waitUntil { isVisible(host) }
        let modeMs = milliseconds(modeStart.duration(to: clock.now))
        let modeStalls = modeStall.end()
        let sameAfterMode = TerminalHostView.inspectionLatest === host
        let modeLines = host.inspectionVisibleText.filter { !$0.isEmpty }.count
        let revealCaptured = profiling ? false : capture(host, name: split ? "split-reveal" : "reveal")
        let phaseAtMode = String(describing: stream.phase)

        var sessionReturned = false
        var sessionMs = -1.0
        var sameAfterSession = false
        var sessionLines = 0
        var sessionMutationMs = -1.0
        var sessionStalls: [String: Any] = [:]
        let other = workspace.feed?.listStore.windowSessions.first(where: {
            $0.key != session.key && !$0.hosted && !$0.live
        })
        if let other, !modeOnly {
            workspace.inspectionRestoreWorkspace(keys: [other.key], focus: other.key)
            _ = await waitUntil { !isVisible(host) }
            let stall = MainThreadStallProbe()
            stall.begin()
            let sessionStart = clock.now
            workspace.inspectionRestoreWorkspace(keys: [session.key], focus: session.key)
            sessionMutationMs = milliseconds(sessionStart.duration(to: clock.now))
            sessionReturned = await waitUntil { isVisible(host) }
            sessionMs = milliseconds(sessionStart.duration(to: clock.now))
            sessionStalls = stall.end()
            sameAfterSession = TerminalHostView.inspectionLatest === host
            sessionLines = host.inspectionVisibleText.filter { !$0.isEmpty }.count
        }

        // Each warm return starts after the previous surface has settled, as a
        // person reading chat or another session would, and its stall window
        // covers the reveal plus the following display commits.
        var chatCaptured = false
        if !profiling {
            workspace.setMode(.chat, for: session.key)
            try? await Task.sleep(for: .milliseconds(600))
            chatCaptured = capture(host, name: split ? "split-chat" : "chat")
            workspace.setMode(.terminal, for: session.key)
            try? await Task.sleep(for: .milliseconds(400))
        }
        var warmModeMs: [Double] = []
        var warmSessionMs: [Double] = []
        var warmModeStallMs: [Int] = []
        var warmSessionStallMs: [Int] = []
        var preservedEveryTime = true
        var warmChatStallMs: [Int] = []
        var chatMeasurements: [Int] = []
        var chatGeometry: [[String: Any]] = []
        var chatRows: [Int] = []
        var iterationAt: [Int] = []
        let loopStart = clock.now
        let iterations = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalReturnLong") ? 60 : 0
        for _ in 0..<(iterations > 0 ? iterations : (profiling ? 30 : 8)) {
            let measuredBefore = MacConversationTableCounters.measurements
            let chatProbe = MainThreadStallProbe()
            chatProbe.begin()
            iterationAt.append(Int(milliseconds(loopStart.duration(to: clock.now))))
            workspace.setMode(.chat, for: session.key)
            _ = await waitUntil { !isVisible(host) }
            try? await Task.sleep(for: .milliseconds(400))
            warmChatStallMs.append(chatProbe.end()["maxMainStallMs"] as? Int ?? -1)
            chatMeasurements.append(MacConversationTableCounters.measurements - measuredBefore)
            chatRows.append(workspace.paneSurfaces.store(for: session.key)?.timelineItems.count ?? -1)
            chatGeometry.append(MacSessionSwitchInspection.renderGeometry(
                workspace.paneSurfaces.existingEntry(for: session.key)?.view,
                store: workspace.paneSurfaces.store(for: session.key)))
            let modeProbe = MainThreadStallProbe()
            modeProbe.begin()
            let modeStarted = clock.now
            workspace.setMode(.terminal, for: session.key)
            _ = await waitUntil { isVisible(host) }
            warmModeMs.append(milliseconds(modeStarted.duration(to: clock.now)))
            try? await Task.sleep(for: .milliseconds(150))
            warmModeStallMs.append(modeProbe.end()["maxMainStallMs"] as? Int ?? -1)
            preservedEveryTime = preservedEveryTime && TerminalHostView.inspectionLatest === host
                && host.inspectionVisibleText.contains(where: { !$0.isEmpty })

            if let other, !modeOnly {
                workspace.inspectionRestoreWorkspace(keys: [other.key], focus: other.key)
                _ = await waitUntil { !isVisible(host) }
                try? await Task.sleep(for: .milliseconds(400))
                let sessionProbe = MainThreadStallProbe()
                sessionProbe.begin()
                let sessionStarted = clock.now
                workspace.inspectionRestoreWorkspace(keys: [session.key], focus: session.key)
                _ = await waitUntil { isVisible(host) }
                warmSessionMs.append(milliseconds(sessionStarted.duration(to: clock.now)))
                try? await Task.sleep(for: .milliseconds(150))
                warmSessionStallMs.append(sessionProbe.end()["maxMainStallMs"] as? Int ?? -1)
                preservedEveryTime = preservedEveryTime && TerminalHostView.inspectionLatest === host
                    && host.inspectionVisibleText.contains(where: { !$0.isEmpty })
            }
        }

        write([
            "hosted": session.hosted,
            "live": session.live,
            "hiddenAfterChat": hiddenAfterChat,
            "modeReturned": modeReturned,
            "modeReturnMs": modeMs,
            "modeMutationMs": modeMutationMs,
            "modeStalls": modeStalls,
            "sameNativeViewAfterMode": sameAfterMode,
            "screenLinesAtModeReveal": modeLines,
            "phaseAtModeReveal": phaseAtMode,
            "sessionReturned": sessionReturned,
            "sessionReturnMs": sessionMs,
            "sessionMutationMs": sessionMutationMs,
            "sessionStalls": sessionStalls,
            "sameNativeViewAfterSession": sameAfterSession,
            "screenLinesAtSessionReveal": sessionLines,
            "warmModeReturnMs": warmModeMs,
            "warmSessionReturnMs": warmSessionMs,
            "warmModeMaxStallMs": warmModeStallMs,
            "warmSessionMaxStallMs": warmSessionStallMs,
            "metalRenderer": host.inspectionUsesMetal,
            "preservedEveryTime": preservedEveryTime,
            "splitKeys": splitKeys.count,
            "revealCaptured": revealCaptured,
            "chatCaptured": chatCaptured,
            "sessionRuntime": session.runtime ?? "",
            "sessionKey": session.key,
            "sessionCwd": SessionPresentation.fullWorkspacePath(from: session),
            "sessionAttention": String(describing: session.attention),
            "warmChatMaxStallMs": warmChatStallMs,
            "chatMeasurements": chatMeasurements,
            "chatGeometry": chatGeometry,
            "chatTimelineItems": chatRows,
            "iterationAtMs": iterationAt,
        ])
    }

    /// Cold production chat against disposable in-memory histories. No host
    /// request, saved tail or user session is changed by this fixture.
    static func inspectColdChatIfRequested(appModel: AppModel) async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectColdChat"), !coldStarted else { return }
        coldStarted = true
        // The owner scenario starts in an already running terminal, not during
        // application/connection startup or restoration of the other panes.
        try? await Task.sleep(for: .seconds(3))
        var results: [[String: Any]] = []
        for (count, width, scale) in [(80, 900.0, 1.0), (400, 900.0, 1.0),
                                      (2000, 900.0, 1.0), (2000, 420.0, 1.5)] {
            let store = ConversationStore(sessionKey: "inspection-cold-\(count)", client: nil, live: false)
            let messages = (1...count).map { index in
                RichMessage(seq: index, role: index.isMultiple(of: 2) ? "assistant" : "user",
                            text: index.isMultiple(of: 2)
                                ? "## Reply \(index)\n\n" + String(repeating: "Native chat paragraph 中文 with **bold** and `code`. ", count: 60)
                                : "Question \(index): inspect this conversation.")
            }
            guard let data = try? JSONEncoder().encode(messages),
                  let list = try? JSONSerialization.jsonObject(with: data),
                  let payload = try? JSONSerialization.data(withJSONObject: ["messages": list, "oldest_seq": 1, "newest_seq": count]),
                  let snapshot = try? JSONDecoder().decode(SessionMessagesResponse.self, from: payload) else { continue }
            let clock = ContinuousClock()
            let projectionStart = clock.now
            store.applySnapshot(snapshot)
            let projectionMs = milliseconds(projectionStart.duration(to: clock.now))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 780),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let document = MacConversationTextDocument()
            let root = NSHostingView(rootView: AnyView(ChatView(store: store, runtimeID: "codex")
                .environment(appModel).environment(\.interfaceScale, scale)
                .environment(\.macConversationTextDocument, document)))
            root.sizingOptions = []
            let before = MacConversationTableCounters.measurements
            let probe = MainThreadStallProbe()
            probe.begin()
            let start = clock.now
            window.contentView = root
            window.orderBack(nil)
            _ = await waitUntil {
                !(MacSessionSwitchInspection.renderGeometry(root, store: store)["blank"] as? Bool ?? true)
            }
            let firstContentMs = milliseconds(start.duration(to: clock.now))
            try? await Task.sleep(for: .milliseconds(150))
            var result = MacSessionSwitchInspection.renderGeometry(root, store: store)
            result["retainedItems"] = store.timelineItems.count
            result["width"] = width
            result["scale"] = scale
            result["projectionMs"] = projectionMs
            result["firstContentMs"] = firstContentMs
            result["measurements"] = MacConversationTableCounters.measurements - before
            result["stalls"] = probe.end()
            results.append(result)
            window.close()
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-cold-chat.json"), options: .atomic)
        }
    }

    /// Window content through `NSView.cacheDisplay`; not a desktop screenshot.
    private static func capture(_ host: NSView, name: String) -> Bool {
        guard let content = host.window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: "/tmp/corral-terminal-return-\(name).png"))) != nil
    }

    private static func isVisible(_ view: NSView) -> Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func write(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-terminal-return.json"), options: .atomic)
    }
}
#endif
