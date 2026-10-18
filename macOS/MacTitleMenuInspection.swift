#if DEBUG
import AppKit
import Foundation

/// Debug-only window top bar acceptance (`-CorralInspectTitleMenu`, usually
/// with `-CorralInspectConversation`): after the window settles, records the
/// title bar's views (class, frame, title, menu) and renders the title bar
/// through `NSView.cacheDisplay`; never a pointer event.
@MainActor
enum MacTitleMenuInspection {
    static func run() async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectTitleMenu") else { return }
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
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-title-menu.json"), options: .atomic)
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
