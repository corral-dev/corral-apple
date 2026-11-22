#if DEBUG
import AppKit
import SwiftUI

/// `-CorralInspectLocalHostSetup` runs the pairing screen's this-Mac flow
/// headlessly against the real host: detection with and without the current
/// pairings, then the Connect action (re-pairing this Mac exactly as pasting
/// its link would). `-CorralInspectLocalHostInstall` also runs the Homebrew
/// install step. Results: /tmp/corral-mac-local-host-setup.json.
@MainActor enum MacLocalHostSetupInspection {
    private static var claimed = false

    static func run(appModel: AppModel) async {
        guard !claimed else { return }
        claimed = true
        var report: [String: Any] = ["sandboxed": MacHostCommand.isSandboxed]
        let setup = MacLocalHostSetup()
        await setup.refresh(pairedHostIDs: Set(appModel.hosts.map(\.hostID)))
        report["statePaired"] = describe(setup.state)
        await setup.refresh(pairedHostIDs: [])
        report["stateUnpaired"] = describe(setup.state)
        report["homebrew"] = MacHostCommand.locateHomebrew()?.path ?? NSNull()
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectLocalHostInstall"),
           let brew = MacHostCommand.locateHomebrew() {
            do {
                try await MacHostCommand.installCorral(brew: brew)
                report["install"] = "ok"
            } catch {
                report["install"] = error.localizedDescription
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectLocalHostCancel") {
            report["cancel"] = await inspectCancel(appModel: appModel)
        }
        if !ProcessInfo.processInfo.arguments.contains("-CorralInspectLocalHostSkipConnect"),
           case .ready(let corral) = setup.state {
            let hostID = await MacHostCommand.localHostID(corral: corral)
            report["localHostID"] = hostID ?? NSNull()
            var paired = false
            setup.connect(corral: corral, appModel: appModel) { paired = true }
            report["stateDuringConnect"] = describe(setup.state)
            for _ in 0..<600 {
                if case .running = setup.state { try? await Task.sleep(for: .milliseconds(200)) } else { break }
            }
            report["paired"] = paired
            report["stateAfterConnect"] = describe(setup.state)
            report["hostPresent"] = appModel.hosts.contains { $0.hostID == hostID }
            report["connection"] = String(describing: appModel.connectionState)
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-local-host-setup.json"), options: .atomic)
        }
    }

    /// Cancels an installation whose stand-in Homebrew starts a long-running
    /// child, then checks that both processes ended and the state recovered.
    private static func inspectCancel(appModel: AppModel) async -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "corral-fake-brew-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let brew = directory.appending(path: "brew")
        let marker = directory.appending(path: "child.pid").path
        let script = "#!/bin/sh\n/bin/sleep 300 &\necho $! > '\(marker)'\nwait\n"
        try? script.write(to: brew, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let setup = MacLocalHostSetup()
        await setup.refresh(pairedHostIDs: [])
        setup.install(brew: brew, appModel: appModel) {}
        var result: [String: Any] = [:]
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let child = (try? String(contentsOfFile: marker, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        result["stateBeforeCancel"] = describe(setup.state)
        result["childRunningBeforeCancel"] = child > 0 && kill(child, 0) == 0
        let started = ContinuousClock.now
        setup.cancel(pairedHostIDs: [])
        for _ in 0..<50 {
            if case .running = setup.state { try? await Task.sleep(for: .milliseconds(100)) } else { break }
        }
        try? await Task.sleep(for: .milliseconds(500))
        result["childRunningAfterCancel"] = child > 0 && kill(child, 0) == 0
        result["stateAfterCancel"] = describe(setup.state)
        result["cancelSeconds"] = Double((ContinuousClock.now - started).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - started).components.seconds)
        return result
    }

    /// `-CorralInspectPairingStates` renders the real pairing view across
    /// full-window and sheet states, light and dark, offscreen to
    /// /tmp/corral-pairing-*.png.
    static func renderStates(appModel: AppModel) {
        let corral = URL(fileURLWithPath: "/opt/homebrew/bin/corral")
        let fullWindowStates: [(String, MacLocalHostSetup.State)] = [
            ("ready", .ready(corral: corral)), ("install", .needsInstall(brew: corral)),
            ("homebrew", .needsHomebrew), ("installing", .running(.installing)),
            ("failed", .failed("Error: No available formula with the name \"x0c/tap/corral\".")),
            ("hidden", .hidden),
        ]
        for (name, state) in fullWindowStates {
            for dark in [false, true] {
                let view = MacPairingView(localSetup: MacLocalHostSetup(inspectionState: state))
                    .modifier(MacZoomContent())
                    .tint(Palette.accent)
                    .environment(\.controlActiveState, .key)
                    .environment(appModel)
                render(view, width: 760, height: 520, dark: dark, name: name)
            }
        }
        let sheetStates: [(String, MacLocalHostSetup.State, String, String?)] = [
            ("sheet-ready", .ready(corral: corral), "", nil),
            ("sheet-hidden", .hidden, "", nil),
            ("sheet-filled", .ready(corral: corral), "corral://pair?h=abc123&k=demo", nil),
            ("sheet-error", .ready(corral: corral), "corral://pair?h=bad", String(localized: "pairing.error.unrecognized")),
        ]
        for (name, state, link, error) in sheetStates {
            for dark in [false, true] {
                let view = MacPairingView(
                    isSheet: true,
                    localSetup: MacLocalHostSetup(inspectionState: state),
                    inspectionLink: link,
                    inspectionError: error
                )
                .modifier(MacZoomContent())
                .tint(Palette.accent)
                .environment(\.controlActiveState, .key)
                .frame(width: 480)
                .environment(appModel)
                render(view, width: 480, height: nil, dark: dark, name: name)
            }
        }
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?, dark: Bool, name: String) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let height {
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        } else {
            host.sizingOptions = [.preferredContentSize]
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            let fitted = host.fittingSize
            host.frame = NSRect(x: 0, y: 0, width: width, height: max(fitted.height, 200))
        }
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: "/tmp/corral-pairing-\(name)-\(dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.close()
    }

    private static func describe(_ state: MacLocalHostSetup.State) -> String {
        switch state {
        case .checking: "checking"
        case .hidden: "hidden"
        case .ready(let corral): "ready \(corral.path)"
        case .needsInstall(let brew): "needsInstall \(brew.path)"
        case .needsScriptInstall: "needsScriptInstall"
        case .needsHomebrew: "needsHomebrew"
        case .running(let step): "running \(step)"
        case .failed(let message): "failed \(message)"
        }
    }
}
#endif
