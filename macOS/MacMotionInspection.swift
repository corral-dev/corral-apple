#if DEBUG
import AppKit
import SwiftUI

/// Debug-only motion acceptance (`-CorralInspectMotion`), so motion is checked
/// on the real window without driving the pointer. Uses the disposable
/// `corral-phone-acceptance` session as the terminal pane and two ended
/// sessions as chat panes; adds, closes, switches and focuses panes on a
/// timer, records frame pacing and how often the terminal view's frame changed
/// during each step, and writes `/tmp/corral-mac-motion.json`. Every pane it
/// opened is closed again, so the host group it formed dissolves.
@MainActor
enum MacMotionInspection {
    static let resultPath = "/tmp/corral-mac-motion.json"

    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        // Choose sessions outside groups only once the host's groups are known.
        for _ in 0..<50 where workspace.layout.revision == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let sessions = feed.listStore.windowSessions
        let acceptance = sessions.first(where: {
            SessionPresentation.fullWorkspacePath(from: $0).contains("corral-phone-acceptance")
        })
        let ended = sessions.filter {
            // Ended, nothing pending (opening a pane marks it read), in no group.
            !$0.live && !$0.hosted && $0.attention == .none && $0.key != acceptance?.key
                && workspace.layout.group(containing: $0.key) == nil
        }
        // Without the disposable acceptance session, B is a third ended
        // session shown as chat (the terminal checks are skipped).
        guard ended.count >= (acceptance == nil ? 3 : 2), let probe = acceptance ?? ended.dropFirst(2).first else {
            write(["error": "needs two ended sessions outside groups (three without the acceptance session)"])
            return
        }
        let chatA = ended[0], chatC = ended[1]
        let probeMode = workspace.mode(for: probe.key)
        let probeView: MacWorkspace.PaneMode = acceptance == nil ? .chat : .terminal
        workspace.setMode(probeView, for: probe.key)

        let recorder = MotionRecorder()
        var steps: [[String: Any]] = []
        func step(_ name: String, settle: Double = 2.5, _ action: () -> Void) async {
            try? await Task.sleep(for: .seconds(settle))
            // Marker for an external sampler, written shortly before the action.
            try? name.write(toFile: "/tmp/corral-mac-motion-step.txt", atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .milliseconds(300))
            recorder.begin(name: name)
            action()
            // Split motion state: offsets set with the change, exits pending,
            // and offsets set once a closed pane has faded out.
            var motion: [String: Any] = [
                "shiftsAtStart": workspace.paneShifts.mapValues { Int($0) },
                "leavingAtStart": Array(workspace.leavingPanes.keys),
            ]
            try? await Task.sleep(for: .seconds(MacMotion.seconds(MacMotion.paneExitSeconds) + 0.01))
            motion["shiftsAfterExit"] = workspace.paneShifts.mapValues { Int($0) }
            try? await Task.sleep(for: .milliseconds(800 * MacMotion.inspectionSlowdown))
            motion["shiftsAtEnd"] = workspace.paneShifts.count
            motion["drawnAtEnd"] = workspace.drawnPaneKeys
            steps.append(recorder.end().merging(motion) { $1 })
        }

        await step("open chat A (instant)") { workspace.open(chatA.key, sessions: sessions) }
        // A pane add writes a host group: add only if the panes are still the
        // probe's own (a click or a sidebar re-selection may have replaced
        // them), so no live session is ever grouped with the probe's sessions.
        var changedPanes: [String]?
        func add(_ session: SessionSummary, after expected: [String]) {
            guard workspace.paneKeys == expected else { changedPanes = workspace.paneKeys; return }
            workspace.addPane(session.key, project: session.cwd)
        }
        func abortIfChanged() -> Bool {
            guard let changedPanes else { return false }
            workspace.paneKeys.filter { [chatA.key, probe.key, chatC.key].contains($0) }.forEach(workspace.closePane)
            workspace.setMode(probeMode, for: probe.key)
            write(["error": "panes changed outside the probe: \(changedPanes)", "steps": steps])
            NSApp.terminate(nil)
            return true
        }
        await step("add terminal B", settle: 3) { add(probe, after: [chatA.key]) }
        if abortIfChanged() { return }
        await step("add chat C", settle: 5) { add(chatC, after: [chatA.key, probe.key]) }
        if abortIfChanged() { return }
        // Closing the middle pane: C glides left into the freed slot.
        await step("close terminal B", settle: 3) { workspace.closePane(probe.key) }
        await step("add terminal B again", settle: 3) { add(probe, after: [chatA.key, chatC.key]) }
        if abortIfChanged() { return }
        await step("close chat C", settle: 3) { workspace.closePane(chatC.key) }
        if acceptance != nil {
            await step("B to chat") { workspace.setMode(.chat, for: probe.key) }
            await step("B to terminal") { workspace.setMode(.terminal, for: probe.key) }
        }
        await step("focus A") { workspace.focus(chatA.key) }
        await step("focus B") { workspace.focus(probe.key) }
        await step("close B") { workspace.closePane(probe.key) }
        await step("back to A (instant)") { workspace.open(chatA.key, sessions: sessions) }

        try? await Task.sleep(for: .seconds(2))
        workspace.closePane(chatA.key)
        workspace.setMode(probeMode, for: probe.key)
        write([
            "slowdown": MacMotion.inspectionSlowdown,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "sessions": ["A": chatA.key, "B": probe.key, "C": chatC.key],
            "steps": steps,
        ])
        // Free the pairing for other clients (two clients on one pairing interfere).
        NSApp.terminate(nil)
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: resultPath))
    }
}

/// Frame intervals from the window's display link, plus frame-change counts of
/// every terminal host view, for one step.
@MainActor
final class MotionRecorder: NSObject {
    private var name = ""
    private var started = Date()
    private var timestamps: [CFTimeInterval] = []
    private var link: CADisplayLink?
    private var terminalFrames = 0
    private var terminalCount = 0
    private var observers: [NSObjectProtocol] = []

    func begin(name: String) {
        self.name = name
        started = Date()
        timestamps = []
        terminalFrames = 0
        let contents = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
        guard let main = contents.max(by: { $0.bounds.width < $1.bounds.width }) else { return }
        link = main.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        terminalCount = 0
        for view in contents.flatMap({ Self.terminalViews(in: $0.window?.contentView?.superview ?? $0) }) {
            terminalCount += 1
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.terminalFrames += 1 }
            })
        }
    }

    func end() -> [String: Any] {
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let intervals = zip(timestamps.dropFirst(), timestamps).map { ($0 - $1) * 1000 }
        let sorted = intervals.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return [
            "step": name,
            "startedAt": ISO8601DateFormatter.withFractions.string(from: started),
            "frames": timestamps.count,
            "medianFrameMs": (median * 10).rounded() / 10,
            "maxFrameMs": ((sorted.last ?? 0) * 10).rounded() / 10,
            "hitches": intervals.filter { median > 0 && $0 > median * 1.5 }.count,
            "terminalViews": terminalCount,
            "terminalFrameChanges": terminalFrames,
            // Offset (ms from the step start) and length of each long frame.
            "longFrames": zip(timestamps.dropFirst(), timestamps).compactMap { end, start -> String? in
                let length = (end - start) * 1000
                guard length > 25 else { return nil }
                return "\(Int((start - (timestamps.first ?? start)) * 1000))+\(Int(length))"
            },
        ]
    }

    @objc private func tick(_ link: CADisplayLink) {
        timestamps.append(link.timestamp)
    }

    private static func terminalViews(in view: NSView) -> [NSView] {
        (view is TerminalHostView ? [view] : []) + view.subviews.flatMap(terminalViews(in:))
    }
}

/// Main-thread responsiveness independent of window visibility: a background
/// thread posts to the main queue every 4 ms and records how late each post
/// ran. Display-link gaps lie for a window behind others; this does not.
nonisolated final class MainThreadStallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stalls: [(at: Double, ms: Double)] = []
    private var running = false
    private var start = Date()

    func begin() {
        lock.lock(); stalls = []; running = true; start = Date(); lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                guard go else { return }
                let posted = Date()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let late = Date().timeIntervalSince(posted) * 1000
                if late > 20 {
                    lock.lock(); stalls.append((posted.timeIntervalSince(start) * 1000, late)); lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    func end() -> [String: Any] {
        lock.lock(); running = false; let found = stalls; lock.unlock()
        return [
            "mainStalls": found.map { "\(Int($0.at))+\(Int($0.ms))" },
            "maxMainStallMs": Int(found.map(\.ms).max() ?? 0),
            "mainStallTotalMs": Int(found.map(\.ms).reduce(0, +)),
        ]
    }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
#endif
