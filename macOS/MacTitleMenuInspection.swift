#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Debug-only window top bar acceptance (`-CorralInspectTitleMenu`, usually
/// with `-CorralInspectConversation`): after the window settles, records the
/// title bar's views (class, frame, title, menu) and whether the focused
/// pane's session menu items keep template symbols under the app tint
/// (built through `NSHostingMenu`); never a pointer event.
@MainActor
enum MacTitleMenuInspection {
    static func run(appModel: AppModel, workspace: MacWorkspace, session: @escaping () -> SessionSummary?) async {
        let inspectContext = ProcessInfo.processInfo.arguments.contains("-CorralInspectPaneContextMenu")
        guard inspectContext || ProcessInfo.processInfo.arguments.contains("-CorralInspectTitleMenu") else { return }
        try? await Task.sleep(for: .seconds(8))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }),
              let frameView = window.contentView?.superview else { return }
        var views: [[String: Any]] = []
        walk(frameView, depth: 0, into: &views, window: window)
        let report: [String: Any] = [
            "windowTitle": window.title,
            "subtitle": window.subtitle,
            "toolbarItems": window.toolbar?.items.map { "\($0.itemIdentifier.rawValue) \(type(of: $0)) \($0.label)" } ?? [],
            "views": views,
            "sessionMenu": sessionMenuImages(appModel: appModel, workspace: workspace, session: session()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-title-menu.json"), options: .atomic)
        }
        if inspectContext, let session = session(),
           let pane = workspace.paneSurfaces.existingEntry(for: session.key)?.view,
           let event = NSEvent.mouseEvent(with: .rightMouseDown, location: pane.convert(NSPoint(x: 80, y: 120), to: nil),
               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
               context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
           let menu = pane.menu(for: event) {
            // Query and present the production native menu directly. No
            // pointer event is posted and no session action is invoked.
            menu.update()
            let items = menu.items.map { ["title": $0.title, "enabled": $0.isEnabled,
                                         "separator": $0.isSeparatorItem] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pane-context-menu.json"), options: .atomic)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { menu.cancelTracking() }
            menu.popUp(positioning: nil, at: NSPoint(x: 80, y: 120), in: pane)
        }
    }

    /// The production session menu under the app's brand tint, converted by
    /// AppKit; template images invert with a highlighted row's text.
    private static func sessionMenuImages(appModel: AppModel, workspace: MacWorkspace,
                                          session: SessionSummary?) -> [String] {
        guard let session else { return ["no session"] }
        let menu = NSHostingMenu(rootView: MacSessionMenuItems(
            session: session, runtimes: workspace.runtimes,
            mode: .constant(workspace.mode(for: session.key)), onClose: {})
            .environment(appModel)
            .environment(workspace)
            .tint(Palette.accent))
        menu.update()
        return menu.items.filter { !$0.isSeparatorItem }.map {
            "\($0.title) image=\($0.image != nil) template=\($0.image?.isTemplate ?? false)"
        }
    }

    private static func walk(_ view: NSView, depth: Int, into views: inout [[String: Any]], window: NSWindow) {
        let frame = view.convert(view.bounds, to: nil)
        // Only the title bar band at the top of the window.
        if frame.maxY >= window.frame.height - 60, depth < 40 {
            var entry: [String: Any] = [
                "depth": depth,
                "class": String(describing: type(of: view)),
                "frame": NSStringFromRect(frame),
            ]
            if let field = view as? NSTextField { entry["text"] = field.stringValue }
            if let button = view as? NSButton { entry["button"] = button.title; entry["image"] = button.image?.name() ?? "" }
            if view.menu != nil { entry["menu"] = view.menu?.items.map(\.title) ?? [] }
            if let label = view.accessibilityLabel() { entry["axLabel"] = label }
            if let role = view.accessibilityRole() { entry["axRole"] = role.rawValue }
            views.append(entry)
        }
        for child in view.subviews { walk(child, depth: depth + 1, into: &views, window: window) }
    }
}
#endif
