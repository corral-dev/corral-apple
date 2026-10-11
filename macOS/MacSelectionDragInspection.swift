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

    private struct Block {
        let view: NSTextView
        /// Window coordinates (origin bottom-left).
        let frame: CGRect
    }

    private enum EndKind { case firstLine, gapAbove, gapBelow }

    static func run(key: String, workspace: MacWorkspace) async {
        self.workspace = workspace
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectSelectionDrag"),
              ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == key else { return }
        let output = URL(fileURLWithPath: "/tmp/corral-mac-selection-drag.json")
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" }),
                  let content = window.contentView, workspace.paneFrames[key] != nil else { continue }
            // Let the conversation settle at its resting position first.
            try? await Task.sleep(for: .seconds(2))
            guard linkedBlocks(in: content, pane: workspace.paneFrames[key]!).count >= 3 else { continue }
            var results: [[String: Any]] = []
            // Offsets into a hit-verified triple (upper, middle, lower); the
            // triple itself is resolved fresh inside each case.
            let specs: [(String, Int, Int, EndKind)] = [
                ("down-into-next", 0, 1, .firstLine),
                ("down-two-blocks", 0, 2, .firstLine),
                ("down-into-gap", 0, 1, .gapAbove),
                ("up-into-previous", 1, 0, .firstLine),
                ("up-two-blocks", 2, 0, .firstLine),
                ("up-into-gap", 1, 0, .gapBelow),
                // A press without travel must leave a caret, not a selection.
                ("click-places-caret", 1, 1, .firstLine),
            ]
            for (name, fromOffset, toOffset, endKind) in specs {
                results.append(await drag(name: name, window: window, content: content,
                                          pane: workspace.paneFrames[key]!,
                                          fromOffset: fromOffset, toOffset: toOffset, endKind: endKind))
            }
            let report: [String: Any] = ["linkedVisibleBlocks": linkedBlocks(in: content, pane: workspace.paneFrames[key]!).count,
                                         "cases": results,
                                         "allPassed": results.allSatisfy { ($0["passed"] as? Bool) == true }]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output)
            }
            return
        }
        try? "{\"error\":\"Fewer than three visible linked message blocks\"}".write(to: output, atomically: true, encoding: .utf8)
    }

    /// Three consecutive blocks whose first lines all land on their own text
    /// views. Rows under the toolbar or behind floating buttons fail this;
    /// a real drag can only start on text the pointer can reach.
    private static func anchorTriple(in blocks: [Block], content: NSView) -> (Block, Block, Block)? {
        guard blocks.count >= 3 else { return nil }
        for i in 0...(blocks.count - 3) {
            let triple = (blocks[i], blocks[i + 1], blocks[i + 2])
            let points = [firstLine(triple.0), firstLine(triple.1), firstLine(triple.2)]
            let views = [triple.0.view, triple.1.view, triple.2.view]
            let ok = zip(points, views).allSatisfy { hitTest($0, in: content) === $1 }
            if ok { return triple }
        }
        return nil
    }

    private static func hitTest(_ windowPoint: CGPoint, in content: NSView) -> NSView? {
        content.hitTest(content.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    }

    private static func drag(name: String, window: NSWindow, content: NSView, pane: CGRect,
                             fromOffset: Int, toOffset: Int, endKind: EndKind) async -> [String: Any] {
        func fail(_ reason: String) -> [String: Any] {
            ["case": name, "passed": false, "error": reason]
        }
        guard let triple = anchorTriple(in: linkedBlocks(in: content, pane: pane), content: content) else {
            return fail("no hit-verified triple")
        }
        let roles = [triple.0, triple.1, triple.2]
        guard roles.indices.contains(fromOffset), roles.indices.contains(toOffset) else { return fail("bad offsets") }
        // Fresh points: the live conversation reflows (streaming, focus), so
        // anything computed before this case's settle sleep may be stale.
        roles[fromOffset].view.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let fresh = linkedBlocks(in: content, pane: pane)
        func refind(_ block: Block) -> Block? {
            fresh.first { $0.view === block.view }
        }
        guard let from = refind(roles[fromOffset]), let to = refind(roles[toOffset]) else {
            return fail("anchor recycled during settle")
        }
        guard hitTest(firstLine(from), in: content) === from.view else {
            return fail("anchor covered after settle")
        }
        let start = firstLine(from)
        let end: CGPoint = {
            switch endKind {
            case .firstLine: return firstLine(to)
            case .gapAbove: return gapAbove(to)
            case .gapBelow: return gapBelow(to)
            }
        }()
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
        var route: [String: Any] = [:]
        if let document = from.view.layoutManager?.delegate as? MacConversationTextDocument {
            let fromLocal = from.view.convert(start, from: nil)
            let toLocal = to.view.convert(end, from: nil)
            route = ["startInBounds": from.view.bounds.contains(fromLocal),
                     "endInBounds": to.view.bounds.contains(toLocal),
                     "startLocal": NSStringFromPoint(fromLocal),
                     "endLocal": NSStringFromPoint(toLocal),
                     "fromRange": "\(document.range(of: from.view) ?? NSRange(location: -1, length: 0))",
                     "toRange": "\(document.range(of: to.view) ?? NSRange(location: -1, length: 0))",
                     "startRoute": document.debugRoute(at: start, in: window),
                     "endRoute": document.debugRoute(at: end, in: window)]
        }
        if let down {
            // Reproduce the window's click path without activating the app
            // (NSApp/NSWindow delivery would bring a background app forward).
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
                "hitPath": hitPath(of: hit, under: content),
                "windowWasKey": wasKey, "appWasActive": wasActive, "leftoverEvents": leftovers,
                "trace": MacConversationTextDocument.selectionTrace.map { "\($0.0):\($0.1)" },
                "route": route]
    }

    /// Superview chain over a hit view, naming whatever covers the text.
    private static func hitPath(of hit: NSView?, under content: NSView) -> [String] {
        var path: [String] = []
        var current = hit
        while let view = current, view !== content, path.count < 6 {
            path.append(String(describing: type(of: view)))
            current = view.superview
        }
        return path
    }

    /// Visible message blocks of one conversation network, top to bottom.
    /// Only fully visible blocks qualify: a real drag can only start on seen
    /// text, and the top rows slide under the toolbar where hit-testing lands
    /// on the toolbar instead of the message.
    private static func linkedBlocks(in content: NSView, pane: CGRect) -> [Block] {
        let texts = descendants(content).compactMap { $0 as? NSTextView }.filter { text in
            guard !text.isEditable, text.isSelectable, text.layoutManager?.textContainers.count ?? 0 > 1 else { return false }
            let rect = text.convert(text.visibleRect, to: nil)
            guard rect.height > 30 else { return false }
            // The whole row must be on screen, not just a visible sliver.
            guard text.visibleRect.height >= text.bounds.height - 2 else { return false }
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
