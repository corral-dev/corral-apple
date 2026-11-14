#if DEBUG
import AppKit
import Foundation
import SwiftTerm

/// Real Pi wheel/trackpad input through the production host and native renderer.
/// Restricted to an owned disposable session; no system pointer input or payload capture.
@MainActor
final class MacTerminalScrollInspection {
    private static var started = false

    private struct Sample {
        let index: Int
        let planned: TimeInterval
        let event: TimeInterval
        var returned: TimeInterval?
        let requestedDelta: Double
        let precise: Bool
        let expectedLines: Int
    }

    private struct Feed {
        let start: TimeInterval
        let end: TimeInterval
        let changed: Bool
    }

    private let output: URL
    private var samples: [Sample] = []
    private var inputStages: [[String: Any]] = []
    private var feeds: [Feed] = []
    private var frameTimes: [TimeInterval] = []
    private var heartbeatLag: [Double] = []
    private var report: [String: Any] = [:]
    private var lastScreen = ""
    private var contentProbe = false
    private var initialGlobalFeedCount = 0
    private var initialGlobalFeedBytes = 0

    private init(output: URL) { self.output = output }

    static func run(workspace: MacWorkspace, appModel: AppModel, feed: HostSessionFeed) async {
        let env = ProcessInfo.processInfo.environment
        guard !started, let key = env["CORRAL_INSPECTION_SESSION_KEY"], key.hasPrefix("pi:"),
              let path = env["CORRAL_INSPECTION_SCROLL_OUTPUT"] else { return }
        started = true
        let probe = MacTerminalScrollInspection(output: URL(fileURLWithPath: path))
        probe.contentProbe = env["CORRAL_INSPECTION_SCROLL_CONTENT_PROBE"] == "1"
        probe.report["contentProbe"] = probe.contentProbe
        probe.save("waiting-for-session")
        guard await wait(seconds: 30, { feed.listStore.session(for: key) != nil }),
              let session = feed.listStore.session(for: key),
              session.cwd.contains("corral-phone-acceptance-typing-") else {
            probe.save("owned-session-not-found")
            return
        }
        let original = (workspace.paneKeys, workspace.focusedKey)
        defer { workspace.inspectionRestoreWorkspace(keys: original.0, focus: original.1) }
        workspace.setMode(.terminal, for: key)
        workspace.inspectionRestoreWorkspace(keys: [key], focus: key)
        guard await wait(seconds: 30, {
            guard let terminal = workspace.terminals.terminal(for: key, client: appModel.client) else { return false }
            return terminal.stream.phase == .live && terminal.view.isShown && terminal.view.hasScreen
        }), let terminal = workspace.terminals.terminal(for: key, client: appModel.client) else {
            probe.save("terminal-not-ready")
            return
        }
        if let identity = env["CORRAL_INSPECTION_SCROLL_IDENTITY"] {
            terminal.view.inspectionSetIdentityBackground(identity == "watermark")
        }
        if let displayName = env["CORRAL_INSPECTION_SCROLL_DISPLAY"] {
            guard let screen = NSScreen.screens.first(where: { $0.localizedName == displayName }),
                  let window = terminal.view.window else {
                probe.save("capture-display-not-found")
                return
            }
            let area = screen.visibleFrame.insetBy(dx: 30, dy: 30)
            window.setFrame(NSRect(x: area.minX, y: area.minY,
                                   width: min(1180, area.width), height: min(900, area.height)), display: true)
        }
        if let renderer = env["CORRAL_INSPECTION_SCROLL_RENDERER"] {
            do { try terminal.view.inspectionUseMetal(renderer == "metal") }
            catch {
                probe.save("renderer-change-failed")
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        let visibilityPolicy = terminal.view.inspectionSuspendsRenderingWhenNotVisible
        let benchmarkVisibility = env["CORRAL_INSPECTION_SCROLL_BENCHMARK_VISIBILITY"] == "1"
        if benchmarkVisibility { terminal.view.inspectionSuspendsRenderingWhenNotVisible = false }
        defer { terminal.view.inspectionSuspendsRenderingWhenNotVisible = visibilityPolicy }
        terminal.view.window?.makeKeyAndOrderFront(nil)
        terminal.view.window?.orderFrontRegardless()
        terminal.view.inspectionFocus()
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<30 where terminal.view.window?.occlusionState.contains(.visible) == false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        probe.report = [
            "session": key,
            "retainedTerminalCount": workspace.terminals.inspectionCount,
            "usesMetal": terminal.view.inspectionUsesMetal,
            "usesRenderLoop": terminal.view.inspectionUsesRenderLoop,
            "usesIdentityBackground": terminal.view.inspectionUsesIdentityBackground,
            "backgroundOpacity": terminal.view.inspectionBackgroundOpacity,
            "mouseMode": terminal.view.inspectionMouseMode,
            "benchmarkVisibilityOverride": benchmarkVisibility,
            "windowOcclusionVisible": terminal.view.window?.occlusionState.contains(.visible) == true,
            "windowIsVisible": terminal.view.window?.isVisible == true,
            "appActive": NSApp.isActive,
            "windowScreen": terminal.view.window?.screen?.localizedName ?? "none",
            "windowMaxFPS": terminal.view.window?.screen?.maximumFramesPerSecond ?? 0,
            "windowNumber": terminal.view.window?.windowNumber ?? 0,
            "contentProbe": probe.contentProbe,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        let streamingWorkload = env["CORRAL_INSPECTION_SCROLL_STREAMING"] == "1"
        probe.report["streamingWorkloadSubmitted"] = streamingWorkload
        if streamingWorkload {
            terminal.stream.input.paste("Output integers 1 through 400, one number per line. Do not use tools or add commentary.")
            terminal.stream.input.send([13][...])
            try? await Task.sleep(for: .seconds(12))
        }
        terminal.stream.input.inspectionTiming = { [weak probe] stage, revision, queued in
            probe?.inputStages.append(["stage": stage, "revision": revision, "queue": queued,
                                       "at": ProcessInfo.processInfo.systemUptime])
        }
        terminal.view.inspectionFeedTiming = { [weak probe] start, end, _ in
            probe?.received(start: start, end: end)
        }
        let oldFrameHandler = SwiftTerm.TerminalView.onFramePresented
        SwiftTerm.TerminalView.onFramePresented = { [weak probe] in
            let stamp = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in probe?.frameTimes.append(stamp) }
        }
        defer {
            terminal.stream.input.inspectionTiming = nil
            terminal.view.inspectionFeedTiming = nil
            SwiftTerm.TerminalView.onFramePresented = oldFrameHandler
        }
        let heartbeat = Task { @MainActor [weak probe] in
            while !Task.isCancelled {
                let expected = ProcessInfo.processInfo.systemUptime + 0.016
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                probe?.heartbeatLag.append(max(0, (ProcessInfo.processInfo.systemUptime - expected) * 1000))
            }
        }
        defer { heartbeat.cancel() }
        if probe.contentProbe { probe.lastScreen = terminal.view.inspectionVisibleText.joined() }
        probe.initialGlobalFeedCount = StreamTerminalView.feedCount
        probe.initialGlobalFeedBytes = StreamTerminalView.feedBytes
        terminal.view.inspectionResetDiagnostics()
        probe.save("before-scrolling")
        try? await Task.sleep(for: .seconds(2))

        let cellHeight = terminal.view.inspectionCellHeight
        let deltas: [Int32] = [3, 5, 8, 13, 21, 8, 5, 34]
        let eventCount = 180
        var accumulator = 0.0
        var expectedLines = 0
        let origin = ProcessInfo.processInfo.systemUptime
        for index in 0..<eventCount {
            let planned = origin + Double(index) / 60.0
            let remaining = planned - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            let direction: Int32 = index < eventCount / 2 ? 1 : -1
            let pixels = deltas[index % deltas.count] * direction
            let started = ProcessInfo.processInfo.systemUptime
            guard let delivery = terminal.view.inspectionScrollWheel(pixels: pixels) else { continue }
            accumulator += delivery.delta
            let lines = Int(accumulator / cellHeight)
            accumulator -= Double(lines) * cellHeight
            expectedLines += abs(lines)
            probe.samples.append(Sample(index: index, planned: planned, event: started,
                                        returned: ProcessInfo.processInfo.systemUptime,
                                        requestedDelta: delivery.delta, precise: delivery.precise,
                                        expectedLines: abs(lines)))
            if env["CORRAL_INSPECTION_SCROLL_CAPTURE_MIDPOINT"] == "1", index == eventCount / 2 {
                probe.save("scrolling-half")
            }
        }
        probe.report["expectedWheelLines"] = expectedLines
        _ = await wait(seconds: 10, {
            guard let last = probe.samples.last?.event else { return true }
            return probe.feeds.contains { $0.changed && $0.end >= last } &&
                probe.frameTimes.contains { $0 >= last }
        })
        try? await Task.sleep(for: .seconds(2))
        probe.save("complete")
        // Leave the completed screen mounted long enough for the outer,
        // non-pointer capture helper to inspect it before workspace restoration.
        try? await Task.sleep(for: .seconds(3))
    }

    private func received(start: TimeInterval, end: TimeInterval) {
        // The callback runs after parsing, so compare the new visible screen
        // without retaining its text in the report.
        guard contentProbe else {
            feeds.append(Feed(start: start, end: end, changed: true))
            return
        }
        let screen = TerminalHostView.inspectionLatest?.inspectionVisibleText.joined() ?? ""
        let changed = screen != lastScreen
        lastScreen = screen
        feeds.append(Feed(start: start, end: end, changed: changed))
    }

    private func save(_ phase: String) {
        report["phase"] = phase
        report["presentationBoundary"] = "Native frame completion after changed parsed content; not physical trackpad-to-pixel latency."
        report["inputStages"] = inputStages
        report["feedCount"] = feeds.count
        report["feeds"] = feeds.map { ["start": $0.start, "end": $0.end, "changed": $0.changed] }
        report["changedFeedCount"] = feeds.filter(\.changed).count
        if let diagnostics = TerminalHostView.inspectionLatest?.inspectionDiagnostics {
            report["globalFeedCount"] = StreamTerminalView.feedCount - initialGlobalFeedCount
        report["globalFeedBytes"] = StreamTerminalView.feedBytes - initialGlobalFeedBytes
        report["rendererDiagnostics"] = [
                "bytesFed": diagnostics.bytesFed, "batches": diagnostics.batches,
                "ticks": diagnostics.ticks, "frames": diagnostics.frames,
                "idleTicks": diagnostics.idleTicks, "renders": diagnostics.renders,
                "renderLoopFrames": diagnostics.renderLoopFrames,
                "renderLoopCoalesced": diagnostics.renderLoopCoalesced,
                "metalRowsRebuilt": diagnostics.metalRowsRebuilt,
            ]
        }
        report["frameTimes"] = frameTimes
        report["heartbeatMaxLagMs"] = heartbeatLag.max() ?? 0
        report["frameCount"] = frameTimes.count
        report["queuedInputCount"] = inputStages.filter { ($0["stage"] as? String) == "queued" }.count
        report["retryCount"] = inputStages.filter { ($0["stage"] as? String) == "retry" }.count
        report["droppedBatchCount"] = inputStages.filter { ($0["stage"] as? String) == "drop" }.count
        report["samples"] = samples.map { sample in
            var row: [String: Any] = [
                "index": sample.index,
                "eventAt": sample.event,
                "scheduledDispatchLagMs": (sample.event - sample.planned) * 1000,
                "requestedDelta": sample.requestedDelta,
                "precise": sample.precise,
                "expectedLines": sample.expectedLines,
            ]
            if let returned = sample.returned { row["nativeScrollHandlerMs"] = (returned - sample.event) * 1000 }
            if let feed = feeds.first(where: { $0.changed && $0.end >= sample.event }) {
                row["eventToChangedFeedMs"] = (feed.end - sample.event) * 1000
                if let frame = frameTimes.first(where: { $0 >= feed.end }) {
                    row["eventToChangedFrameMs"] = (frame - sample.event) * 1000
                }
            }
            return row
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
        } catch { debugTrace("terminal scroll inspection report failed: \(error)") }
    }

    private static func wait(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
#endif
