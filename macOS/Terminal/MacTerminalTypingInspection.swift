#if DEBUG
import AppKit
import Foundation
import SwiftTerm

/// Actual window key events → production input sender → fresh Pi → native frames.
/// Restricted to the owned disposable cwd; never submits a prompt or moves the pointer.
@MainActor
final class MacTerminalTypingInspection {
    private static var started = false

    private struct Sample {
        let expected: String
        let planned: TimeInterval
        let key: TimeInterval
        var returned: TimeInterval?
        var feed: TimeInterval?
        var parsed: TimeInterval?
        var presented: TimeInterval?
    }

    private var samples: [Sample] = []
    private var inputStages: [[String: Any]] = []
    private var feeds: [[String: Any]] = []
    private var frameTimes: [TimeInterval] = []
    private var heartbeatLag: [Double] = []
    private weak var view: TerminalHostView?
    private let output: URL
    private var report: [String: Any] = [:]

    private init(output: URL) { self.output = output }

    static func run(workspace: MacWorkspace, appModel: AppModel, feed: HostSessionFeed) async {
        let env = ProcessInfo.processInfo.environment
        guard !started, let key = env["CORRAL_INSPECTION_SESSION_KEY"], key.hasPrefix("pi:"),
              let path = env["CORRAL_INSPECTION_TYPING_OUTPUT"] else { return }
        started = true
        let probe = MacTerminalTypingInspection(output: URL(fileURLWithPath: path))
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
        probe.view = terminal.view
        if let displayName = env["CORRAL_INSPECTION_TYPING_DISPLAY"] {
            guard let screen = NSScreen.screens.first(where: { $0.localizedName == displayName }),
                  let window = terminal.view.window else {
                probe.save("capture-display-not-found")
                return
            }
            let area = screen.visibleFrame.insetBy(dx: 30, dy: 30)
            window.setFrame(NSRect(x: area.minX, y: area.minY,
                                   width: min(1180, area.width), height: min(900, area.height)), display: true)
        }
        let visibilityPolicy = terminal.view.inspectionSuspendsRenderingWhenNotVisible
        let benchmarkVisibility = env["CORRAL_INSPECTION_TYPING_BENCHMARK_VISIBILITY"] == "1"
        if benchmarkVisibility { terminal.view.inspectionSuspendsRenderingWhenNotVisible = false }
        defer { terminal.view.inspectionSuspendsRenderingWhenNotVisible = visibilityPolicy }
        terminal.view.window?.makeKeyAndOrderFront(nil)
        terminal.view.inspectionFocus()
        try? await Task.sleep(for: .seconds(2))
        probe.report = ["session": key, "usesMetal": terminal.view.inspectionUsesMetal,
                        "benchmarkVisibilityOverride": benchmarkVisibility,
                        "windowOcclusionVisible": terminal.view.window?.occlusionState.contains(.visible) == true,
                        "windowScreen": terminal.view.window?.screen?.localizedName ?? "none",
                        "appHidden": NSApp.isHidden,
                        "keyboardFocus": terminal.view.inspectionHasKeyboardFocus,
                        "windowNumber": terminal.view.window?.windowNumber ?? 0,
                        "pid": ProcessInfo.processInfo.processIdentifier]
        let streamingWorkload = env["CORRAL_INSPECTION_TYPING_STREAMING"] == "1"
        probe.report["streamingWorkloadSubmitted"] = streamingWorkload
        if streamingWorkload {
            terminal.stream.input.paste("Output integers 1 through 400, one number per line. Do not use tools or add commentary.")
            terminal.stream.input.send([13][...])
            try? await Task.sleep(for: .seconds(1))
        }
        terminal.stream.input.send(Array("ZQ7_".utf8)[...])
        guard await wait(seconds: 10, { terminal.view.inspectionContains("ZQ7_") }) else {
            probe.save("seed-not-echoed")
            return
        }
        terminal.stream.input.inspectionTiming = { [weak probe] stage, revision, queued in
            probe?.inputStages.append(["stage": stage, "revision": revision, "queue": queued,
                                       "at": ProcessInfo.processInfo.systemUptime])
        }
        terminal.view.inspectionFeedTiming = { [weak probe] start, end, data in
            probe?.received(start: start, end: end, data: data)
        }
        let oldFrameHandler = SwiftTerm.TerminalView.onFramePresented
        SwiftTerm.TerminalView.onFramePresented = { [weak probe] in
            let stamp = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in probe?.presented(at: stamp) }
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
        probe.save("before-typing")
        try? await Task.sleep(for: .seconds(3))
        let text = "abcdefghijklmnopqrstuvwxyz0123456789中文测试"
        var expected = "ZQ7_"
        let origin = ProcessInfo.processInfo.systemUptime
        let initialFeedCount = StreamTerminalView.feedCount
        let initialFeedBytes = StreamTerminalView.feedBytes
        for (index, character) in text.enumerated() {
            let planned = origin + Double(index) * 0.080
            let remaining = planned - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            expected.append(character)
            probe.samples.append(Sample(expected: expected, planned: planned, key: ProcessInfo.processInfo.systemUptime))
            terminal.view.inspectionPressKeys([String(character)])
            probe.samples[probe.samples.count - 1].returned = ProcessInfo.processInfo.systemUptime
        }
        _ = await wait(seconds: 5, { probe.samples.allSatisfy { $0.presented != nil } })
        probe.report["finalTextPresent"] = terminal.view.inspectionContains(expected)
        probe.report["feedCountDuringTyping"] = StreamTerminalView.feedCount - initialFeedCount
        probe.report["feedBytesDuringTyping"] = StreamTerminalView.feedBytes - initialFeedBytes
        probe.report["keyboardFocusAfter"] = terminal.view.inspectionHasKeyboardFocus
        probe.save("typed")
        try? await Task.sleep(for: .seconds(8))
        terminal.view.inspectionPressKeys(Array(repeating: "\u{7f}", count: text.count + 4))
        try? await Task.sleep(for: .seconds(1))
        probe.report["draftCleared"] = !terminal.view.inspectionContains("ZQ7_")
        probe.save("complete")
    }

    private func received(start: TimeInterval, end: TimeInterval, data: Data) {
        feeds.append(["start": start, "end": end, "data": data.base64EncodedString()])
        guard let view else { return }
        let text = view.inspectionVisibleText.joined()
        for index in samples.indices where samples[index].parsed == nil && text.contains(samples[index].expected) {
            samples[index].feed = start
            samples[index].parsed = end
            if let frame = frameTimes.first(where: { $0 >= end }) { samples[index].presented = frame }
        }
    }

    private func presented(at time: TimeInterval) {
        frameTimes.append(time)
        for index in samples.indices where samples[index].presented == nil {
            if let parsed = samples[index].parsed, time >= parsed { samples[index].presented = time }
        }
    }

    private func save(_ phase: String) {
        report["phase"] = phase
        report["presentationBoundary"] = "First native frame completion after a matching parsed echo; not physical key-to-pixel latency."
        report["inputStages"] = inputStages
        report["feeds"] = feeds
        report["frameTimes"] = frameTimes
        report["heartbeatMaxLagMs"] = heartbeatLag.max() ?? 0
        report["frameCount"] = frameTimes.count
        report["samples"] = samples.enumerated().map { index, sample in
            var row: [String: Any] = ["index": index, "keyAt": sample.key,
                                      "scheduledDispatchLagMs": (sample.key - sample.planned) * 1000]
            if let returned = sample.returned { row["nativeKeyHandlerMs"] = (returned - sample.key) * 1000 }
            if let feed = sample.feed { row["keyToFeedMs"] = (feed - sample.key) * 1000 }
            if let parsed = sample.parsed, let feed = sample.feed { row["parseMs"] = (parsed - feed) * 1000 }
            if let presented = sample.presented { row["keyToFrameMs"] = (presented - sample.key) * 1000 }
            return row
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
        } catch { debugTrace("terminal typing inspection report failed: \(error)") }
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
