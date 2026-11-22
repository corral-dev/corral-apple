#if DEBUG
import AppKit

/// Debug-only: `-CorralInspectResizeSweep` resizes the main window through a
/// range of widths without the pointer and logs layout cost per step to
/// /tmp/corral-inspect.log, then leaves the window at
/// `CORRAL_INSPECTION_WINDOW_WIDTH` (default 931) for a capture.
enum MacResizeInspection {
    static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-CorralInspectSidebarResize") {
            // Let the requested size, pairing and conversation loads settle before
            // moving only the sidebar divider in the mounted window.
            async let sizing: Void = applyRequestedSize()
            await inspectSidebarResize()
            await sizing
            return
        }
        await applyRequestedSize()
        guard arguments.contains("-CorralInspectResizeSweep") else { return }
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

    /// Move the actual system divider at a fixed window size. This exercises
    /// native column layout, not pointer delivery or display cadence.
    private static func inspectSidebarResize() async {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CORRAL_INSPECTION_SIDEBAR_RESIZE_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let capture = environment["CORRAL_INSPECTION_SIDEBAR_RESIZE_FRAMES"] == "1"
        let paneCount = environment["CORRAL_INSPECTION_SESSION_KEY"]?.split(separator: ",").count ?? 0
        let terminalCount = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminal") ? 1 : 0
        guard let (window, content, split) = await waitForSidebar(tables: paneCount - terminalCount,
                                                                terminals: terminalCount) else {
            let tables = visibleViews(in: NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" })?.contentView ?? NSView(),
                                      as: MacConversationTable.ConversationTableView.self)
            let terminals = visibleViews(in: NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" })?.contentView ?? NSView(),
                                         as: TerminalHostView.self)
            debugTrace("sidebar resize: no mounted sidebar divider; expected \(paneCount - terminalCount) tables/\(terminalCount) terminals, saw \(tables.count) tables rows \(tables.map(\.numberOfRows)) and \(terminals.count) terminals screens \(terminals.map(\.hasScreen)) in \(NSApp.windows.map { "\($0.title.isEmpty ? "<untitled>" : $0.title) visible=\($0.isVisible)" })")
            return
        }
        content.layoutSubtreeIfNeeded()
        let windowWidth = window.frame.width
        let originalWidth = split.arrangedSubviews[0].frame.width
        let initial = max(270, split.minPossiblePositionOfDivider(at: 0) + 2)
        let upper = min(410, split.maxPossiblePositionOfDivider(at: 0) - 2)
        guard upper - initial >= 40 else {
            debugTrace("sidebar resize: divider range too small")
            return
        }
        let tables = visibleViews(in: content, as: MacConversationTable.ConversationTableView.self)
        let terminals = visibleViews(in: content, as: TerminalHostView.self)
        let startTerminals = terminals.map(terminalGeometry)
        let steps = Array(0...30) + Array((0..<30).reversed())
        // Attribution switches: layout vs native drawing vs both.
        let skipDraw = environment["CORRAL_INSPECTION_SIDEBAR_RESIZE_SKIP_DRAW"] == "1"
        let skipLayout = environment["CORRAL_INSPECTION_SIDEBAR_RESIZE_SKIP_LAYOUT"] == "1"
        var samples: [[String: Double]] = []
        for (index, step) in steps.enumerated() {
            guard !Task.isCancelled else { break }
            let before = MacConversationTableCounters.measurements
            let beforeMeasureTime = MacConversationTableCounters.measureMs
            let beforeLayouts = MacConversationTableCounters.layoutPasses
            let beforeQueries = MacConversationTableCounters.heightQueries
            let beforeRowLayouts = MacConversationTableCounters.rowLayouts
            let beforeViewFor = MacConversationTableCounters.viewForCalls
            let beforeReflows = MacConversationTableCounters.reflows
            let beforeTableMs = MacConversationTableCounters.layoutPassMs
            let beforeRowMs = MacConversationTableCounters.rowLayoutMs
            let start = ContinuousClock.now
            split.setPosition(initial + (upper - initial) * CGFloat(step) / 30, ofDividerAt: 0)
            let positioned = ContinuousClock.now
            if !skipLayout { content.layoutSubtreeIfNeeded() }
            let laidOut = ContinuousClock.now
            if !skipDraw { window.displayIfNeeded() }
            let displayed = ContinuousClock.now
            let width = split.arrangedSubviews[0].frame.width
            samples.append([
                "sidebarWidth": width, "windowWidth": window.frame.width,
                "chatTableWidth": tables.first?.tableColumns.first?.width ?? 0,
                "terminalWidth": terminals.first?.bounds.width ?? 0,
                "milliseconds": milliseconds(start.duration(to: displayed)),
                "positionMs": milliseconds(start.duration(to: positioned)),
                "layoutMs": milliseconds(positioned.duration(to: laidOut)),
                "displayMs": milliseconds(laidOut.duration(to: displayed)),
                "measurements": Double(MacConversationTableCounters.measurements - before),
                "measureMilliseconds": MacConversationTableCounters.measureMs - beforeMeasureTime,
                "tableLayouts": Double(MacConversationTableCounters.layoutPasses - beforeLayouts),
                "heightQueries": Double(MacConversationTableCounters.heightQueries - beforeQueries),
                "rowLayouts": Double(MacConversationTableCounters.rowLayouts - beforeRowLayouts),
                "viewForCalls": Double(MacConversationTableCounters.viewForCalls - beforeViewFor),
                "reflows": Double(MacConversationTableCounters.reflows - beforeReflows),
                "tableLayoutMs": MacConversationTableCounters.layoutPassMs - beforeTableMs,
                "rowLayoutMs": MacConversationTableCounters.rowLayoutMs - beforeRowMs,
            ])
            if capture, [0, 15, 30, 45, 60].contains(index) {
                writeResizeSample(["index": index, "sidebarWidth": width, "windowID": window.windowNumber],
                                  to: output.appendingPathComponent("frame-\(index).json"))
                try? await Task.sleep(for: .seconds(2))
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let movingTerminals = terminals.map(terminalGeometry)
        try? await Task.sleep(for: .milliseconds(500))
        let settledTerminals = terminals.map(terminalGeometry)
        let settledSidebarWidth = split.arrangedSubviews[0].frame.width
        split.setPosition(originalWidth, ofDividerAt: 0)
        content.layoutSubtreeIfNeeded()
        writeResizeSample([
            "windowWidth": windowWidth, "samples": samples,
            "settledSidebarWidth": settledSidebarWidth,
            "conversationRows": tables.map(\.numberOfRows),
            "conversationWidths": tables.map { $0.tableColumns.first?.width ?? 0 },
            "terminals": ["start": startTerminals, "moving": movingTerminals, "settled": settledTerminals],
        ], to: output.appendingPathComponent("sidebar-resize.json"))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    private static func waitForSidebar(tables expected: Int, terminals terminalCount: Int) async -> (NSWindow, NSView, NSSplitView)? {
        try? await Task.sleep(for: .seconds(9))
        for _ in 0..<100 {
            guard !Task.isCancelled else { return nil }
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" }),
               let content = window.contentView,
               let split = sidebarSplit(in: content) {
                let tables = visibleViews(in: content, as: MacConversationTable.ConversationTableView.self)
                let terminals = visibleViews(in: content, as: TerminalHostView.self)
                if tables.count >= expected, tables.allSatisfy({ $0.numberOfRows > 0 }),
                   terminals.count >= terminalCount, terminals.allSatisfy(\.hasScreen) {
                    return (window, content, split)
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private static func visibleViews<T: NSView>(in view: NSView, as type: T.Type) -> [T] {
        guard !view.isHidden else { return [] }
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { visibleViews(in: $0, as: type) }
    }

    private static func terminalGeometry(_ terminal: TerminalHostView) -> [String: Int] {
        ["width": Int(terminal.bounds.width), "height": Int(terminal.bounds.height),
         "gridCols": terminal.inspectionGrid?.cols ?? 0, "gridRows": terminal.inspectionGrid?.rows ?? 0,
         "voteCols": terminal.inspectionFit?.cols ?? 0, "voteRows": terminal.inspectionFit?.rows ?? 0,
         "votes": terminal.inspectionFitVotes, "fontChanges": terminal.inspectionFontChanges,
         "visibleRows": terminal.inspectionVisibleRows]
    }

    private static func sidebarSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical,
           split.arrangedSubviews.count >= 2,
           let sidebar = split.arrangedSubviews.first,
           !split.isSubviewCollapsed(sidebar), sidebar.frame.width > 0 {
            return split
        }
        for child in view.subviews {
            if let split = sidebarSplit(in: child) { return split }
        }
        return nil
    }

    private static func writeResizeSample(_ report: [String: Any], to url: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            debugTrace("sidebar resize: could not write \(url.lastPathComponent): \(error)")
        }
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
