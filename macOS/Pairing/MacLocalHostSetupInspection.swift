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
        if case .ready(let corral) = setup.state {
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

    /// `-CorralInspectPairingStates` renders the real pairing view in each
    /// this-Mac state, light and dark, offscreen to /tmp/corral-pairing-*.png.
    static func renderStates(appModel: AppModel) {
        let corral = URL(fileURLWithPath: "/opt/homebrew/bin/corral")
        let states: [(String, MacLocalHostSetup.State)] = [
            ("ready", .ready(corral: corral)), ("install", .needsInstall(brew: corral)),
            ("homebrew", .needsHomebrew), ("installing", .running(.installing)),
            ("failed", .failed("Error: No available formula with the name \"x0c/tap/corral\".")),
            ("hidden", .hidden),
        ]
        for (name, state) in states {
            for dark in [false, true] {
                let view = MacPairingView(localSetup: MacLocalHostSetup(inspectionState: state))
                    .modifier(MacZoomContent())
                    .environment(appModel)
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                host.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = URL(fileURLWithPath: "/tmp/corral-pairing-\(name)-\(dark ? "dark" : "light").png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                window.close()
            }
        }
    }

    private static func describe(_ state: MacLocalHostSetup.State) -> String {
        switch state {
        case .checking: "checking"
        case .hidden: "hidden"
        case .ready(let corral): "ready \(corral.path)"
        case .needsInstall(let brew): "needsInstall \(brew.path)"
        case .needsHomebrew: "needsHomebrew"
        case .running(let step): "running \(step)"
        case .failed(let message): "failed \(message)"
        }
    }
}
#endif
