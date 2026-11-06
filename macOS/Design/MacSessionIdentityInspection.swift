#if DEBUG
import AppKit

/// Read-only capture preparation for the production session surfaces. No input
/// or host mutations; restore geometry/render policy after the bounded capture.
enum MacSessionIdentityInspection {
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectSessionIdentity") else { return }
        for _ in 0..<40 where NSApp.windows.first(where: { $0.title == "Corral" }) == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window = NSApp.windows.first(where: { $0.title == "Corral" }) else { return }
        let originalFrame = window.frame
        let env = ProcessInfo.processInfo.environment
        if let name = env["CORRAL_INSPECTION_IDENTITY_DISPLAY"],
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            let area = screen.visibleFrame.insetBy(dx: 24, dy: 24)
            let width = Double(env["CORRAL_INSPECTION_IDENTITY_WIDTH"] ?? "") ?? 1180
            window.setFrame(NSRect(x: area.minX, y: area.minY,
                                   width: min(max(width, window.minSize.width), area.width),
                                   height: min(900, area.height)), display: true)
        }
        defer { window.setFrame(originalFrame, display: true) }
        var terminal: TerminalHostView?
        var originalPolicy = true
        defer {
            if let terminal { terminal.inspectionSuspendsRenderingWhenNotVisible = originalPolicy }
        }
        for _ in 0..<40 {
            if terminal == nil, let view = TerminalHostView.inspectionLatest, view.isShown {
                terminal = view
                originalPolicy = view.inspectionSuspendsRenderingWhenNotVisible
                // A locked desktop makes even awake-display windows occluded.
                // Permit fresh render-server pixels only during this capture.
                view.inspectionSuspendsRenderingWhenNotVisible = false
            }
            let report: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "window": window.windowNumber,
                "screen": window.screen?.localizedName ?? "none",
                "occlusionVisible": window.occlusionState.contains(.visible),
                "captureVisibilityOverride": terminal != nil,
                "terminalRows": terminal?.inspectionVisibleRows ?? 0,
                "metal": terminal?.inspectionUsesMetal ?? false,
                "fontSize": terminal?.inspectionFontSize ?? 0,
                "bottomVisible": terminal?.inspectionBottomVisible ?? false
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/corral-session-identity.json"), options: .atomic)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
#endif
