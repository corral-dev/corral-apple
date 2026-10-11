#if DEBUG
import AppKit

/// Same-window drag-selection acceptance. Mouse events are delivered to this
/// process's own event queue only; the system pointer never moves. Each case
/// starts on one linked message block and drags across a block boundary,
/// then compares the native selection with the characters under both ends
/// and checks that no message moved on screen.
@MainActor
enum MacSelectionDragInspection {
    private static var workspace: MacWorkspace!
    private static var key = ""

    private struct Block {
        let view: NSTextView
        /// Window coordinates (origin bottom-left).
        let frame: CGRect
    }

    static func run(key: String, workspace: MacWorkspace) async {
        self.workspace = workspace
        self.key = key
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectSelectionDrag"),
              ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == key else { return }
        let output = URL(fileURLWithPath: "/tmp/corral-mac-selection-drag.json")
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" }),
                  let content = window.contentView, let pane = workspace.paneFrames[key] else { continue }
            let blocks = linkedBlocks(in: content, pane: pane)
            guard blocks.count >= 3 else { continue }
            // Let the conversation settle at its resting position first.
            try? await Task.sleep(for: .seconds(2))
            let settled = linkedBlocks(in: content, pane: pane)
            guard settled.count >= 3 else { continue }
            var results: [[String: Any]] = []
            let upper = settled[0], middle = settled[1], lower = settled[2]
            let cases: [(String, Block, CGPoint, Block, CGPoint)] = [
                ("down-into-next", upper, firstLine(upper), middle, firstLine(middle)),
                ("down-two-blocks", upper, firstLine(upper), lower, firstLine(lower)),
                ("down-into-gap", upper, firstLine(upper), middle, gapAbove(middle)),
                ("up-into-previous", middle, firstLine(middle), upper, firstLine(upper)),
                ("up-two-blocks", lower, firstLine(lower), upper, firstLine(upper)),
                ("up-into-gap", middle, firstLine(middle), upper, gapBelow(upper)),
            ]
            for (name, from, start, to, end) in cases {
                results.append(await drag(name: name, window: window, content: content, pane: pane,
                                          from: from, start: start, to: to, end: end))
            }
            let report: [String: Any] = ["linkedVisibleBlocks": settled.count, "cases": results,
                                         "allPassed": results.allSatisfy { ($0["passed"] as? Bool) == true }]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output)
            }
            return
        }
        try? "{\"error\":\"Fewer than three visible linked message blocks\"}".write(to: output, atomically: true, encoding: .utf8)
    }

    private static func drag(name: String, window: NSWindow, content: NSView, pane: CGRect,
                             from: Block, start: CGPoint, to: Block, end: CGPoint) async -> [String: Any] {
        from.view.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let before = linkedBlocks(in: content, pane: pane).map(\.frame)
        let startIndex = characterIndex(in: from.view, window: start)
        let endIndex = characterIndex(in: to.view, window: end)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        let down = event(.leftMouseDown, start)
        for step in 1...16 {
            let t = CGFloat(step) / 16
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let drag = event(.leftMouseDragged, point) { NSApp.postEvent(drag, atStart: false) }
        }
        if let up = event(.leftMouseUp, end) { NSApp.postEvent(up, atStart: false) }
        let hit = content.hitTest(content.superview?.convert(start, from: nil) ?? start)
        let wasKey = window.isKeyWindow, wasActive = NSApp.isActive
        if let down {
            // Reproduce the window's click path without activating the app
            // (NSApp/NSWindow delivery would bring a background app forward).
            let steps = Set((ProcessInfo.processInfo.environment["CORRAL_INSPECTION_DRAG_STEPS"] ?? "")
                .split(separator: ",").map(String.init))
            if steps.contains("focus") { workspace.focus(key) }
            if steps.contains("claim") {
                DispatchQueue.main.async { [weak window] in workspace.claimKeysAfterClick(in: key, window: window) }
            }
            if steps.contains("responder"), let hit, hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
            hit?.mouseDown(with: down)
        }
        var leftovers = 0
        // Drop leftovers if the press never entered native tracking.
        while let leftover = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: nil,
                                             inMode: .default, dequeue: true) { _ = leftover; leftovers += 1 }
        let selected = from.view.selectedRange()
        try? await Task.sleep(for: .milliseconds(600))
        let after = linkedBlocks(in: content, pane: pane).map(\.frame)
        let shift = zip(before, after).map { max(abs($0.minY - $1.minY), abs($0.minX - $1.minX)) }.max() ?? -1
        let expected = NSRange(location: min(startIndex, endIndex), length: abs(endIndex - startIndex))
        // A gap between two blocks may resolve to either side of the separator.
        let slack = name.hasSuffix("gap") ? 1 : 0
        let matches = abs(selected.location - expected.location) <= slack
            && abs(NSMaxRange(selected) - NSMaxRange(expected)) <= slack
        let passed = matches && shift < 0.5 && before.count == after.count
        return ["case": name, "selected": "\(selected)", "expected": "\(expected)",
                "maxBlockShift": shift, "passed": passed,
                "firstResponderIsMessage": window.firstResponder is NSTextView,
                "hit": hit.map { String(describing: type(of: $0)) } ?? "nil", "hitIsStartBlock": hit === from.view,
                "windowWasKey": wasKey, "appWasActive": wasActive, "leftoverEvents": leftovers]
    }

    /// Visible message blocks of one conversation network, top to bottom.
    private static func linkedBlocks(in content: NSView, pane: CGRect) -> [Block] {
        let texts = descendants(content).compactMap { $0 as? NSTextView }.filter { text in
            guard !text.isEditable, text.isSelectable, text.layoutManager?.textContainers.count ?? 0 > 1 else { return false }
            let rect = text.convert(text.visibleRect, to: nil)
            guard rect.height > 30 else { return false }
            return pane.contains(CGPoint(x: rect.midX, y: content.bounds.height - rect.maxY + 4))
                && pane.contains(CGPoint(x: rect.midX, y: content.bounds.height - rect.minY - 4))
        }
        return texts.map { Block(view: $0, frame: $0.convert($0.bounds, to: nil)) }
            .filter { $0.frame.height > 30 }
            .sorted { $0.frame.maxY > $1.frame.maxY }
    }

    /// Point a few characters into the first line, in window coordinates.
    private static func firstLine(_ block: Block) -> CGPoint {
        guard let layout = block.view.layoutManager, let container = block.view.textContainer else {
            return CGPoint(x: block.frame.minX + 20, y: block.frame.maxY - 8)
        }
        let glyphs = layout.glyphRange(for: container)
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let local = CGPoint(x: line.minX + min(40, line.width / 2), y: line.midY)
        return block.view.convert(local, to: nil)
    }

    private static func gapAbove(_ block: Block) -> CGPoint {
        CGPoint(x: block.frame.minX + 30, y: block.frame.maxY + 3)
    }

    private static func gapBelow(_ block: Block) -> CGPoint {
        CGPoint(x: block.frame.minX + 30, y: block.frame.minY - 3)
    }

    /// Expected insertion point: inside a block it is the glyph boundary under
    /// the pointer; in a gap it is the end of the block above the gap.
    private static func characterIndex(in view: NSTextView, window point: CGPoint) -> Int {
        let local = view.convert(point, from: nil)
        guard view.bounds.contains(local) else {
            guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
            let range = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
            // The container's trailing separator newline belongs to the message break.
            let message = layout.textStorage.map { ($0.string as NSString).substring(with: range) } ?? ""
            let trimmed = message.hasSuffix("\n") ? range.length - 1 : range.length
            return local.y < 0 ? range.location : range.location + trimmed
        }
        return view.characterIndexForInsertion(at: local)
    }

    private static func descendants(_ root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants($0) }
    }
}
#endif
