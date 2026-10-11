#if DEBUG
import AppKit

/// Debug-only: `-CorralInspectResizeSweep` resizes the main window through a
/// range of widths without the pointer and logs layout cost per step to
/// /tmp/corral-inspect.log, then leaves the window at
/// `CORRAL_INSPECTION_WINDOW_WIDTH` (default 931) for a capture.
enum MacResizeInspection {
    static func runIfRequested() async {
        await applyRequestedSize()
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectResizeSweep") else { return }
        try? await Task.sleep(for: .seconds(12))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Corral" })
            ?? NSApp.windows.first(where: \.isVisible) else { return }
        let finalWidth = CGFloat(Double(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_WINDOW_WIDTH"] ?? "") ?? 931)
        let origin = window.frame.origin
        let height = window.frame.height
        // Programmatic frames ignore the minimum a user drag would stop at.
        let floor = max(900, window.minSize.width)
        debugTrace(String(format: "before sweep: window %.0f, minimum %.0f", window.frame.width, window.minSize.width))
        let widths = Array(stride(from: 1500.0, through: floor, by: -20.0)) + Array(stride(from: floor, through: 1500.0, by: 20.0))
        var costs: [Double] = []
        for width in widths {
            let start = CFAbsoluteTimeGetCurrent()
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            costs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            await Task.yield()
        }
        let sorted = costs.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        debugTrace(String(format: "resize sweep: %d steps, median %.1f ms, p95 %.1f ms, max %.1f ms",
                          costs.count, median, p95, sorted.last ?? 0))
        window.setFrame(NSRect(x: origin.x, y: origin.y, width: max(finalWidth, window.minSize.width), height: height), display: true)
        try? await Task.sleep(for: .seconds(2))
        let content = window.contentView?.bounds.width ?? 0
        let fitting = window.contentView?.fittingSize.width ?? 0
        debugTrace(String(format: "window %.0f, content %.0f, content fitting %.0f", window.frame.width, content, fitting))
        dumpSplits(window, label: "at \(Int(finalWidth))")
        window.setFrame(NSRect(x: origin.x, y: origin.y, width: 600, height: height), display: true)
        try? await Task.sleep(for: .seconds(1))
        dumpSplits(window, label: "at 600")
        window.setFrame(NSRect(x: origin.x, y: origin.y, width: max(finalWidth, window.minSize.width), height: height), display: true)
    }

    /// `CORRAL_INSPECTION_WINDOW_SIZE=<width>x<height>` gives captures a fixed
    /// main-window frame without a pointer drag. A saved frame can be restored
    /// after the first second, so the size is re-applied until it holds.
    private static func applyRequestedSize() async {
        let parts = (ProcessInfo.processInfo.environment["CORRAL_INSPECTION_WINDOW_SIZE"] ?? "")
            .split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" })
                ?? NSApp.windows.first(where: \.isVisible) else { continue }
            let size = NSSize(width: max(parts[0], window.minSize.width), height: max(parts[1], window.minSize.height))
            if window.frame.size != size {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            }
        }
    }

    /// Every split view in the window with its panes' widths and minimum widths.
    private static func dumpSplits(_ window: NSWindow, label: String) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var lines: [String] = ["layout \(label): window \(Int(window.frame.width))"]
        func walk(_ view: NSView, depth: Int) {
            if let split = view as? NSSplitView {
                let panes = split.arrangedSubviews.map { sub in
                    String(format: "%@ %.0f(fit %.0f, intrinsic %.0f)", String(describing: type(of: sub)).prefix(28) as CVarArg,
                           sub.frame.width, sub.fittingSize.width, sub.intrinsicContentSize.width)
                }
                lines.append("\(String(repeating: " ", count: depth))\(type(of: split)) x=\(Int(split.convert(split.bounds, to: nil).minX)) w=\(Int(split.frame.width)) [\(panes.joined(separator: " | "))]")
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        func deep(_ view: NSView, depth: Int) {
            guard depth < 9 else { return }
            let fit = view.fittingSize.width
            if fit > 250 {
                lines.append(String(format: "%@%@ w=%.0f fit=%.0f", String(repeating: "  ", count: depth),
                                    String(describing: type(of: view)).prefix(60) as CVarArg, view.frame.width, fit))
            }
            for sub in view.subviews { deep(sub, depth: depth + 1) }
        }
        var inner: NSSplitView?
        func find(_ view: NSView) {
            if let split = view as? NSSplitView, split.arrangedSubviews.count >= 3 { inner = split }
            view.subviews.forEach(find)
        }
        find(root)
        if let first = inner?.arrangedSubviews.first { deep(first, depth: 0) }
        walk(root, depth: 0)
        debugTrace(lines.joined(separator: "\n"))
    }
}
#endif
