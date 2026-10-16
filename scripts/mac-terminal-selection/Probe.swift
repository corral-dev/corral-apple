import AppKit
import SwiftTerm

@main
struct TerminalSelectionProbe {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let view = StreamTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.resize(cols: 80, rows: 24)

        // Pi redraws changed rows with CRLF. A status line below the reply
        // must not end a native selection, including during range extension.
        feed(view, "Select this stable reply\r\n中文回复 keeps its selection")
        view.selection.startSelection(row: 0, col: 0)
        view.selection.dragExtend(bufferPosition: Position(col: 6, row: 0))
        for tick in 0..<30 {
            feed(view, "\u{1b}[?2026h\u{1b}[6;1H\u{1b}[2Kspinner \(tick)\r\n\u{1b}[?2026l")
            require(view.selection.active, "selection survives an unrelated live redraw")
            require(view.selection.getSelectedText() == "Select", "selected reply text remains unchanged")
        }
        view.selection.dragExtend(bufferPosition: Position(col: 11, row: 0))
        require(view.selection.getSelectedText() == "Select this", "range still extends after redraws")
        require(view.allowMouseReporting, "agent mouse reporting remains enabled")
        verifyCopy(view, expected: "Select this")

        view.allowMouseReporting = false
        view.feedFromHost(Data())
        feed(view, "\u{1b}[6;1Hstatus without newline")
        require(!view.allowMouseReporting && view.selection.active,
                "empty and cursor-only chunks preserve selection and a disabled mouse gate")
        view.allowMouseReporting = true

        view.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 8, row: 1))
        let unicode = view.selection.getSelectedText()
        feed(view, "\u{1b}[6;1Hstatus\r\n")
        require(view.selection.active && view.selection.getSelectedText() == unicode,
                "Unicode selection survives output")

        // A Shift-select in a mouse-aware agent must survive the same output;
        // preserving it must not require disabling the agent's mouse modes.
        feed(view, "\u{1b}[?1003h\u{1b}[?1006h\u{1b}[6;1Hstatus\r\n")
        require(view.selection.active && view.selection.getSelectedText() == unicode,
                "local selection survives output in a mouse-aware terminal")

        // Keep the native engine's row adjustment. Scroll a region in place:
        // first move the selected row, then scroll its text out of the region.
        feed(view, "\u{1b}[?1003l\u{1b}[?1006l\u{1b}[2;4r\u{1b}[2;1Hfirst\u{1b}[3;1Hselected\u{1b}[4;1Hlast")
        view.selection.setSelection(start: Position(col: 0, row: 2), end: Position(col: 8, row: 2))
        feed(view, "\u{1b}[4;1H\r\n")
        require(view.selection.active && view.selection.start.row == 1
                && view.selection.getSelectedText() == "selected",
                "native scrolling moves the selection with its text")
        feed(view, "\u{1b}[4;1H\r\n")
        require(!view.selection.active, "native scrolling drops text that left the region")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        feed(view, "\u{1b}[?1049h")
        require(!view.selection.active, "alternate screen does not inherit an unrelated selection")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        feed(view, "\u{1b}[?1049l")
        require(!view.selection.active, "restored normal screen discards alternate-screen selection")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        view.getTerminal().resetToInitialState()
        require(!view.selection.active, "snapshot reset discards the old buffer selection")
        verifyPromptNavigation()
        if let path = CommandLine.arguments.dropFirst().first { verifyPiOutput(path) }
        print("PASS: 30 live redraws, continued range extension, Unicode, mouse mode and native scroll invalidation")
    }

    @MainActor
    private static func verifyPromptNavigation() {
        let view = StreamTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.resize(cols: 40, rows: 12)
        view.changeScrollback(1000)
        let chinese = "USER_15 中文提问需要跨行匹配以及保留正确定位，这是目标文字"
        for i in 0..<120 {
            feed(view, (i == 15 ? chinese : "synthetic row \(i)") + "\r\n")
        }
        let bottom = view.scrollPosition
        require(view.revealPrompt(chinese), "full CJK query preserves final wide glyph at wrap")
        require(view.scrollPosition < bottom, "prompt navigation reveals retained native history")
        view.resize(cols: 24, rows: 12)
        require(view.revealPrompt(chinese), "prompt navigation re-resolves after resize")
        feed(view, "duplicate query\r\nduplicate query\r\n")
        let previous = view.scrollPosition
        require(!view.revealPrompt("duplicate query"), "duplicate text cannot choose the wrong row")
        require(view.scrollPosition == previous, "ambiguity leaves viewport unchanged")
        feed(view, "\u{1b}[?1049h\u{1b}[2J\u{1b}[HCURRENT_ALT_PROMPT")
        require(view.revealPrompt("CURRENT_ALT_PROMPT"), "active alternate text is available")
        require(!view.revealPrompt(chinese), "normal buffer cannot leak through active alternate screen")
        feed(view, "\u{1b}[2J\u{1b}[Hnew screen")
        require(!view.revealPrompt("CURRENT_ALT_PROMPT"), "overwritten alternate text is unavailable")
        print("PASS prompt navigation: complete CJK wrap, resize, duplicate refusal, alternate overwrite")
    }

    @MainActor
    private static func verifyPiOutput(_ path: String) {
        do {
            let chunks = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let view = StreamTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.resize(cols: 80, rows: 24)
            let marker = "Corral stable selection reply"
            var selected = false
            var checked = 0
            for (index, encoded) in chunks.enumerated() {
                guard let bytes = Data(base64Encoded: encoded) else { preconditionFailure("invalid capture chunk") }
                view.feedFromHost(bytes)
                if selected {
                    require(view.selection.active, "real Pi output preserves the active selection")
                    if !view.getTerminal().synchronizedOutputActive {
                        if view.selection.getSelectedText() != marker {
                            let diagnostic = "Pi selected: \(view.selection.getSelectedText().debugDescription), range \(view.selection.start)-\(view.selection.end), checks \(checked)\n"
                            FileHandle.standardError.write(Data(diagnostic.utf8))
                        }
                        require(view.selection.getSelectedText() == marker, "real Pi redraw preserves selected text")
                        checked += 1
                    }
                } else if index >= chunks.count / 2 {
                    // Select after Pi's startup warnings/layout have settled.
                    let terminal = view.getTerminal()
                    for row in 0..<terminal.rows {
                        guard let line = terminal.getLine(row: row)?.translateToString(trimRight: true),
                              let range = line.range(of: marker) else { continue }
                        let col = line.distance(from: line.startIndex, to: range.lowerBound)
                        view.selection.startSelection(row: row, col: col)
                        view.selection.dragExtend(row: row, col: col + marker.count)
                        selected = true
                        break
                    }
                }
            }
            require(checked >= 10, "real Pi capture contains enough subsequent redraws")
            verifyCopy(view, expected: marker)
            print("PASS: actual Pi native output, \(checked) completed chunks retain selection and Copy")
        } catch {
            preconditionFailure("Cannot read Pi capture: \(error)")
        }
    }

    @MainActor
    private static func verifyCopy(_ view: StreamTerminalView, expected: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let snapshot = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { snapshot.setData(data, forType: type) }
            }
            return snapshot
        }
        defer {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        view.copy(view)
        require(pasteboard.string(forType: .string) == expected, "native Copy returns selected text")
    }

    @MainActor
    private static func feed(_ view: StreamTerminalView, _ text: String) {
        view.feedFromHost(Data(text.utf8))
    }

    private static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
}
