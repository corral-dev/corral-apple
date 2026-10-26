import AppKit
import SwiftTerm

/// Offscreen native events exercise selection without moving the user's pointer.
@main
struct TerminalSelectionProbe {
    @MainActor private static var windows: [NSWindow] = []

    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { windows.forEach { $0.close() } }
        let view = makeView()
        view.resize(cols: 80, rows: 24)
        feed(view, "Select this stable reply\r\n中文回复 keeps its selection")
        select(view, start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        for tick in 0..<30 {
            feed(view, "\u{1b}[?2026h\u{1b}[6;1H\u{1b}[2Kspinner \(tick)\r\n\u{1b}[?2026l")
            require(view.selectionActive, "selection survives an unrelated live redraw")
            require(view.getSelection() == "Select", "selected reply text remains unchanged")
        }
        extend(view, to: Position(col: 11, row: 0))
        require(view.getSelection() == "Select this", "range still extends after redraws")
        require(view.allowMouseReporting, "agent mouse reporting remains enabled")
        verifyCopy(view, expected: "Select this")
        view.allowMouseReporting = false
        view.feedFromHost(Data())
        feed(view, "\u{1b}[6;1Hstatus without newline")
        require(!view.allowMouseReporting && view.selectionActive,
                "empty and cursor-only chunks preserve selection and a disabled mouse gate")
        view.allowMouseReporting = true
        select(view, start: Position(col: 0, row: 1), end: Position(col: 8, row: 1))
        let unicode = view.getSelection()
        feed(view, "\u{1b}[6;1Hstatus\r\n")
        require(view.selectionActive && view.getSelection() == unicode, "Unicode selection survives output")
        feed(view, "\u{1b}[?1003h\u{1b}[?1006h\u{1b}[6;1Hstatus\r\n")
        require(view.selectionActive && view.getSelection() == unicode,
                "selection survives output in a mouse-aware terminal")
        feed(view, "\u{1b}[?1003l\u{1b}[?1006l\u{1b}[2;4r\u{1b}[2;1Hfirst\u{1b}[3;1Hselected\u{1b}[4;1Hlast")
        select(view, start: Position(col: 0, row: 2), end: Position(col: 8, row: 2))
        feed(view, "\u{1b}[4;1H\r\n")
        require(view.selectionActive && view.getSelection() == "selected", "scrolling moves selection with its text")
        feed(view, "\u{1b}[4;1H\r\n")
        require(!view.selectionActive, "scrolling invalidates text that left the region")
        select(view, start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        feed(view, "\u{1b}[?1049h")
        require(!view.selectionActive, "alternate screen discards normal selection")
        feed(view, "ALT text")
        select(view, start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        feed(view, "\u{1b}[?1049l")
        require(!view.selectionActive, "normal screen discards alternate selection")
        select(view, start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        view.resetToInitialState()
        require(!view.selectionActive, "snapshot reset discards old selection")
        verifyPromptNavigation()
        verifyResyncViewport()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--prompt-snapshot"), arguments.indices.contains(index + 1) {
            verifyPromptSnapshot(arguments[index + 1])
        } else if let path = arguments.first { verifyPiOutput(path) }
        print("PASS live redraws, native range extension/Copy, Unicode, mouse modes and scroll invalidation")
    }

    @MainActor
    private static func makeView() -> StreamTerminalView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = StreamTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        // Selection/engine acceptance is independent of the GPU surface. The
        // installed-window scenario separately verifies the default renderer.
        do { try view.setUseMetal(false) } catch { preconditionFailure("renderer setup: \(error)") }
        view.changeScrollback(10_000)
        window.contentView = view
        windows.append(window)
        return view
    }

    @MainActor
    private static func mouse(_ view: StreamTerminalView, _ type: NSEvent.EventType,
                              _ position: Position, shift: Bool = false) {
        guard let window = view.window else { preconditionFailure("missing fixture window") }
        let grid = view.terminalDimensions
        let optimal = view.getOptimalFrameSize()
        let point = NSPoint(x: (CGFloat(position.col) + 0.2) * optimal.width / CGFloat(grid.cols),
                            y: view.bounds.maxY - (CGFloat(position.row) + 0.5) * optimal.height / CGFloat(grid.rows))
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        else { preconditionFailure("fixture event") }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: preconditionFailure("unexpected event")
        }
    }

    @MainActor
    private static func select(_ view: StreamTerminalView, start: Position, end: Position) {
        view.selectNone()
        mouse(view, .leftMouseDown, start)
        mouse(view, .leftMouseDragged, end)
        mouse(view, .leftMouseUp, end)
    }

    @MainActor
    private static func extend(_ view: StreamTerminalView, to end: Position) {
        mouse(view, .leftMouseDown, end, shift: true)
        mouse(view, .leftMouseUp, end, shift: true)
    }

    @MainActor
    private static func verifyPromptNavigation() {
        let view = makeView()
        view.resize(cols: 40, rows: 12)
        let chinese = "USER_15 中文提问需要跨行匹配以及保留正确定位，这是目标文字"
        for index in 0..<120 { feed(view, (index == 15 ? chinese : "synthetic row \(index)") + "\r\n") }
        let bottom = view.scrollPosition
        require(view.revealPrompt(chinese), "CJK wrap preserves final wide glyph")
        require(view.scrollPosition < bottom, "prompt reveals actual retained history")
        view.resize(cols: 24, rows: 12)
        require(view.revealPrompt(chinese), "prompt re-resolves after resize")
        feed(view, "duplicate query\r\nduplicate query\r\n")
        let previous = view.scrollPosition
        require(!view.revealPrompt("duplicate query"), "ambiguous text refuses ordinal guessing")
        require(view.scrollPosition == previous, "ambiguity leaves viewport unchanged")
        for index in 0..<50 { feed(view, "middle \(index)\r\n") }
        feed(view, "duplicate query\r\n")
        for index in 0..<30 { feed(view, "tail \(index)\r\n") }
        require(view.revealPrompt("duplicate query", occurrence: 0, total: 3), "first duplicate is located")
        let first = view.scrollPosition
        require(view.revealPrompt("duplicate query", occurrence: 2, total: 3), "last duplicate is located")
        require(view.scrollPosition > first, "duplicate identity chooses different buffer row")
        let selected = view.scrollPosition
        require(!view.revealPrompt("duplicate query", occurrence: 2, total: 4), "partial history refuses guessing")
        require(view.scrollPosition == selected, "incomplete evidence leaves viewport unchanged")
        feed(view, "\u{1b}[?1049h\u{1b}[2J\u{1b}[HCURRENT_ALT_PROMPT")
        require(view.revealPrompt("CURRENT_ALT_PROMPT"), "active alternate text available")
        feed(view, "\u{1b}[5;1HLOWER_ALT_PROMPT")
        require(!view.revealPrompt("LOWER_ALT_PROMPT"), "lower unscrollable alternate row is not top-edge success")
        require(!view.revealPrompt(chinese), "normal history cannot leak through alternate screen")
        feed(view, "\u{1b}[2J\u{1b}[Hnew screen")
        require(!view.revealPrompt("CURRENT_ALT_PROMPT"), "overwritten text unavailable")
        print("PASS prompt CJK wrap, resize, duplicate identity, partial history and alternate overwrite")
    }

    @MainActor
    private static func verifyResyncViewport() {
        let view = makeView()
        view.resize(cols: 80, rows: 24)
        let recent = (500..<2000).map { "retained row \($0)" }.joined(separator: "\r\n")
        view.feedFromHost(Data(recent.utf8))
        view.scrollTo(row: 100)
        let top = view.visibleRowsText(0..<1).first
        view.preservingViewportDuringSnapshot {
            view.resetToInitialState()
            view.feedFromHost(Data((0..<2000).map { "retained row \($0)" }.joined(separator: "\r\n").utf8))
        }
        require(view.visibleRowsText(0..<1).first == top, "resync preserves another reader's visible row")
        view.scroll(toPosition: 0)
        view.preservingViewportDuringSnapshot {
            view.resetToInitialState()
            view.feedFromHost(Data((0..<2000).map { "retained row \($0)" }.joined(separator: "\r\n").utf8))
        }
        require(view.terminalStateSnapshot().viewportRow == 0, "top-edge reader survives resync")
        view.scroll(toPosition: 1)
        view.preservingViewportDuringSnapshot { view.resetToInitialState(); view.feedFromHost(Data(recent.utf8)) }
        require(view.scrollPosition == 1, "live viewer remains live after resync")
        view.scrollUp(lines: 5)
        view.preservingViewportDuringSnapshot {
            view.resize(cols: 90, rows: 30)
            view.resetToInitialState()
            view.feedFromHost(Data((0..<2000).map { "retained row \($0)" }.joined(separator: "\r\n").utf8))
        }
        require(view.scrollPosition == 1, "resized resync returns a reader to live output, not the top")
        view.scrollUp(lines: 5)
        view.preservingViewportDuringSnapshot(hostGridChanged: true) {
            view.resetToInitialState()
            view.feedFromHost(Data((0..<1200).map { "retained row \($0)" }.joined(separator: "\r\n").utf8))
        }
        require(view.scrollPosition == 1, "a host grid change already applied to the emulator still returns to live")
        print("PASS resync viewport retention and live edge")
        verifyHistoryErase()
    }

    /// Pi's full redraw (`tui-main-screen.js` fullRender) erases scrollback and
    /// rewrites the whole transcript; a reader must not be left on its first line.
    @MainActor
    private static func verifyHistoryErase() {
        func transcript(_ count: Int, _ tag: String) -> String {
            (0..<count).map { "\(tag) row \($0)" }.joined(separator: "\r\n")
        }
        let redraw = "\u{1b}[?2026h\u{1b}[2J\u{1b}[H\u{1b}[3J" + transcript(3000, "new") + "\u{1b}[?2026l"
        for (label, chunks) in [("one chunk", [redraw]),
                                ("split after ED 3", [String(redraw.prefix(40)), String(redraw.dropFirst(40))])] {
            let view = makeView()
            view.resize(cols: 80, rows: 24)
            feed(view, transcript(3000, "old"))
            view.scrollUp(lines: 5)
            chunks.forEach { feed(view, $0) }
            require(view.scrollPosition == 1 && view.visibleRowsText(23..<24).first == "new row 2999",
                    "reader returns to live output after a full redraw (\(label))")
        }
        let live = makeView()
        live.resize(cols: 80, rows: 24)
        feed(live, transcript(12_000, "old"))
        feed(live, redraw)
        require(live.scrollPosition == 1, "live viewer stays live through a full redraw")
        let reader = makeView()
        reader.resize(cols: 80, rows: 24)
        feed(reader, transcript(12_000, "old"))
        reader.scrollUp(lines: 200)
        let top = reader.visibleRowsText(0..<1).first
        feed(reader, "\r\n" + transcript(500, "more"))
        require(reader.scrollPosition < 1 && reader.visibleRowsText(0..<1).first == top,
                "ordinary output keeps a reader's text in place at full scrollback")
        print("PASS history erase returns readers to live output")
    }

    @MainActor
    private static func verifyPromptSnapshot(_ path: String) {
        struct Fixture: Decodable { let cols: Int; let rows: Int; let data: String; let query: String; let expectedReveal: Bool? }
        do {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let view = makeView()
            view.resize(cols: fixture.cols, rows: fixture.rows)
            guard let data = Data(base64Encoded: fixture.data) else { preconditionFailure("invalid snapshot") }
            view.feedFromHost(data)
            let bottom = view.scrollPosition
            let found = view.revealPrompt(fixture.query)
            if fixture.expectedReveal == false {
                require(!found, "baseline physical-line snapshot reproduces lost-wrap miss")
                print("PASS old physical-row snapshot baseline")
                return
            }
            require(found, "real tmux snapshot preserves CJK query beyond 500 rows")
            require(view.scrollPosition < bottom, "real snapshot moves native viewport")
            require(view.visibleRowsText(0..<1).first?.contains("native prompt margin prefix") == true,
                    "selected real prompt lands at top edge")
            print("PASS actual host capture, wrapping, retention and top-edge arrival")
        } catch { preconditionFailure("snapshot fixture: \(error)") }
    }

    @MainActor
    private static func verifyPiOutput(_ path: String) {
        do {
            let chunks = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let view = makeView()
            view.resize(cols: 80, rows: 24)
            let marker = "Corral stable selection reply"
            var selected = false
            var checked = 0
            for (index, encoded) in chunks.enumerated() {
                guard let bytes = Data(base64Encoded: encoded) else { preconditionFailure("invalid capture") }
                view.feedFromHost(bytes)
                if selected {
                    require(view.selectionActive && view.getSelection() == marker, "real Pi redraw retains selected text")
                    checked += 1
                } else if index >= chunks.count / 2 {
                    for (row, line) in view.visibleRowsText(0..<view.terminalDimensions.rows).enumerated() {
                        guard let range = line.range(of: marker) else { continue }
                        let col = line.distance(from: line.startIndex, to: range.lowerBound)
                        select(view, start: Position(col: col, row: row), end: Position(col: col + marker.count, row: row))
                        selected = true
                        break
                    }
                }
            }
            require(checked >= 10, "Pi fixture contains enough subsequent redraws")
            verifyCopy(view, expected: marker)
            print("PASS actual Pi output: \(checked) subsequent chunks retain native selection/Copy")
        } catch { preconditionFailure("Pi capture: \(error)") }
    }

    @MainActor
    private static func verifyCopy(_ view: StreamTerminalView, expected: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let snapshot = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { snapshot.setData(data, forType: type) } }
            return snapshot
        }
        defer { pasteboard.clearContents(); if !saved.isEmpty { pasteboard.writeObjects(saved) } }
        view.copy(view)
        require(pasteboard.string(forType: .string) == expected, "native Copy returns selected text")
    }

    @MainActor private static func feed(_ view: StreamTerminalView, _ text: String) {
        view.feedFromHost(Data(text.utf8))
    }
    private static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
}
