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
            "sessionMenu": sessionMenuImages(appModel: appModel, workspace: workspace, session: session()),
            "continueWithSubmenu": continueWithSubmenuImages(appModel: appModel, workspace: workspace, session: session()),
            "views": views,
            "runtimeCatalog": [
                "loaded": workspace.runtimeCatalog.isLoaded,
                "loading": workspace.runtimeCatalog.isLoading,
                "error": workspace.runtimeCatalog.errorMessage ?? "",
                "runtimes": workspace.runtimes.map(\.id),
            ] as [String: Any],
            "actionSymbols": [SessionActionsMenu.forkSymbol, SessionActionsMenu.handoffSymbol].map {
                ["name": $0, "available": NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil] as [String: Any]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-title-menu.json"), options: .atomic)
        }
        if inspectContext, let session = session(),
           let pane = workspace.paneSurfaces.existingEntry(for: session.key)?.view {
            let target = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminal")
                ? (firstStreamTerminal(in: pane) ?? pane)
                : pane
            let point: NSPoint
            if let terminal = target as? StreamTerminalView {
                point = blankPoint(in: terminal)
            } else {
                point = NSPoint(x: 80, y: 120)
            }
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: target.convert(point, to: nil),
                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                   context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
               let menu = target.menu(for: event) {
                // Query and present the production native menu directly. No
                // pointer event is posted and no session action is invoked.
                let cancelTarget = MenuCancelTarget(menu: menu)
                let timer = Timer(timeInterval: 25, target: cancelTarget,
                                  selector: #selector(MenuCancelTarget.fire), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: .common)
                NotificationCenter.default.addObserver(
                    cancelTarget, selector: #selector(MenuCancelTarget.menuBegan),
                    name: NSMenu.didBeginTrackingNotification, object: menu
                )
                defer {
                    timer.invalidate()
                    NotificationCenter.default.removeObserver(cancelTarget)
                }
                NSMenu.popUpContextMenu(menu, with: event, for: target)
            }
        }
    }

    /// The production session menu under the app's brand tint, converted by
    /// AppKit; template images invert with a highlighted row's text.
    private static func sessionMenuImages(appModel: AppModel, workspace: MacWorkspace,
                                          session: SessionSummary?) -> [String] {
        guard let session else { return ["no session"] }
        let menu = NSHostingMenu(rootView: MacSessionMenuItems(session: session)
            .environment(appModel)
            .environment(workspace)
            .tint(Palette.accent))
        menu.update()
        return menu.items.filter { !$0.isSeparatorItem }.map {
            "\($0.title) image=\($0.image != nil) template=\($0.image?.isTemplate ?? false)"
        }
    }

    private static func continueWithSubmenuImages(appModel: AppModel, workspace: MacWorkspace,
                                                  session: SessionSummary?) -> [String] {
        guard let session else { return ["no session"] }
        let menu = NSHostingMenu(rootView: MacSessionMenuItems(session: session)
            .environment(appModel)
            .environment(workspace)
            .tint(Palette.accent))
        menu.update()
        let continueTitle = String(localized: "mac.session.continue_with")
        guard let submenu = menu.items.first(where: { $0.title == continueTitle })?.submenu else {
            return ["missing submenu"]
        }
        submenu.update()
        return submenu.items.filter { !$0.isSeparatorItem }.map {
            "\($0.title) image=\($0.image != nil)"
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

    private static func blankPoint(in terminal: StreamTerminalView) -> NSPoint {
        for y in stride(from: max(terminal.bounds.height - 24, 24), through: 24, by: -32) {
            for x in stride(from: max(terminal.bounds.width - 24, 24), through: 24, by: -48) {
                let candidate = NSPoint(x: x, y: y)
                if !terminal.isText(at: candidate) { return candidate }
            }
        }
        return NSPoint(x: 80, y: 120)
    }

    private static func firstStreamTerminal(in view: NSView) -> StreamTerminalView? {
        if let terminal = view as? StreamTerminalView { return terminal }
        for child in view.subviews {
            if let found = firstStreamTerminal(in: child) { return found }
        }
        return nil
    }
}

@MainActor
private final class MenuCancelTarget: NSObject {
    weak var menu: NSMenu?
    init(menu: NSMenu) { self.menu = menu }
    @objc func fire() { menu?.cancelTracking() }
    @objc func menuBegan() {
        guard let tracked = menu else { return }
        let items = tracked.items.map {
            ["title": $0.title, "enabled": $0.isEnabled, "separator": $0.isSeparatorItem] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pane-context-menu.json"), options: .atomic)
        }
    }
}
#endif
