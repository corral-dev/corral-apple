import AppKit

@main
struct TextSelectionProbe {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor static func require<T>(_ value: T?, _ message: String) -> T {
        guard let value else { fatalError(message) }
        return value
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let owner = NSObject()
        let document = MacConversationTextDocument()
        var style = MacConversationTextDocument.Style(
            font: .systemFont(ofSize: 14), foreground: .labelColor, userForeground: .labelColor
        )
        var sources: [MacConversationTextDocument.Source] = [
            .init(id: 1, text: "First 中文🙂\nSecond paragraph", isUser: false),
            .init(id: 3, text: "let answer = 42\nprint(answer)", isUser: false),
            .init(id: 4, text: "Last reply", isUser: true),
        ]
        var renderCount = 0
        func update() {
            document.update(identity: ObjectIdentifier(owner), sources: sources, style: style) { source in
                renderCount += 1
                return NSAttributedString(string: source.text, attributes: [
                    .font: source.id == 3 ? NSFont.monospacedSystemFont(ofSize: style.font.pointSize, weight: .regular) : style.font,
                ])
            }
        }
        update()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        window.contentView = root
        var views: [MacDirectMessageTextView] = []
        for (index, source) in sources.enumerated() {
            let view = require(document.textView(for: source.id) as? MacDirectMessageTextView, "missing message view")
            view.frame = NSRect(x: 20, y: index * 170, width: 540, height: 150)
            view.isEditable = false
            view.isSelectable = true
            view.textContainerInset = .zero
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            view.autoresizingMask = [.width]
            root.addSubview(view)
            views.append(view)
        }
        check(window.makeFirstResponder(views[0]), "could not focus native message")
        for source in sources {
            let container = require(document.container(for: source.id), "missing message container")
            let layout = require(document.layout(for: source.id), "missing message layout")
            layout.ensureLayout(for: container)
            let drawn = layout.characterRange(
                forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil
            )
            let expected = require(document.range(for: source.id), "missing message range")
            check(drawn.location == 0 && drawn.length == expected.length,
                  "message \(source.id) spilled: drawn \(drawn), expected \(expected)")
        }

        // Cross-block selection spanning block 1 (index 6..) through block 3 (..18).
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func copied(_ view: MacDirectMessageTextView) -> String? {
            pasteboard.declareTypes([.string], owner: nil)
            check(view.writeSelection(to: pasteboard, types: [.rtf, .string]),
                  "native Copy failed (hasSel=\(document.hasSelection), multi=\(document.hasMultiBlockSelection), local=\(view.selectedRange()))")
            return pasteboard.string(forType: .string)
        }
        document.selectAll(from: views[0])
        check(document.hasMultiBlockSelection, "selectAll did not select across multiple blocks")
        // Narrow to partial cross-block selection: block 1 from 6 to end, block 3 from 0 to 18.
        let p0 = document.position(at: views[0].convert(NSPoint(x: 50, y: 10), to: nil), in: window,
                                   anchor: MacConversationTextDocument.Position(id: 1, offset: 6))
        _ = p0
        let expectedFirst = (require(document.storage(for: 1), "missing s1").string as NSString).substring(from: 6)
        let expectedLast = (require(document.storage(for: 3), "missing s3").string as NSString).substring(to: 18)
        let expectedCopy = expectedFirst + "\n\n" + expectedLast
        // Drive single-view selection reset, then set multi-block selection via mouse drag simulation.
        views[0].setSelectedRange(NSRange(location: 6, length: require(document.storage(for: 1), "s1").length - 6))
        // Directly set cross-block selection by calling singleViewDidChangeSelection? No, test real drag or document API:
        // Simulate a drag from views[0] (offset 6) to views[1] (offset 18).
        let layout0 = require(document.layout(for: 1), "l0"), c0 = require(document.container(for: 1), "c0")
        let layout1 = require(document.layout(for: 3), "l1"), c1 = require(document.container(for: 3), "c1")
        layout0.ensureLayout(for: c0); layout1.ensureLayout(for: c1)
        let g0 = layout0.glyphIndexForCharacter(at: 6)
        let r0 = layout0.boundingRect(forGlyphRange: NSRange(location: g0, length: 1), in: c0)
        let startWin = views[0].convert(NSPoint(x: r0.minX + 0.1, y: r0.midY), to: nil)
        let g1 = layout1.glyphIndexForCharacter(at: 18)
        let r1 = layout1.boundingRect(forGlyphRange: NSRange(location: g1, length: 1), in: c1)
        let endWin = views[1].convert(NSPoint(x: r1.minX + 0.1, y: r1.midY), to: nil)
        func mouseEvent(_ type: NSEvent.EventType, _ pt: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(mouseEvent(.leftMouseDragged, endWin), atStart: false)
        NSApp.postEvent(mouseEvent(.leftMouseUp, endWin), atStart: false)
        views[0].mouseDown(with: mouseEvent(.leftMouseDown, startWin))
        check(document.hasMultiBlockSelection, "drag did not create multi-block selection")
        check(copied(views[0]) == expectedCopy && copied(views[1]) == expectedCopy,
              "Copy lost Unicode or a message boundary: got \((copied(views[0]) ?? "nil").debugDescription) expected \(expectedCopy.debugDescription)")
        check(pasteboard.data(forType: .rtf) != nil, "rich-text copying was lost")

        let before = renderCount
        update()
        check(renderCount == before, "unchanged messages were rerendered")
        sources.insert(.init(id: 0, text: "Earlier history", isUser: false), at: 0)
        update()
        check(renderCount == before + 1, "prepending history rerendered unchanged messages")
        check(copied(views[0]) == expectedCopy, "prepending history changed selected content")
        check(window.firstResponder === views[0], "history update stole keyboard focus")
        for source in sources {
            let layout = require(document.layout(for: source.id), "missing layout")
            let container = require(document.container(for: source.id), "missing container")
            layout.ensureLayout(for: container)
        }
        sources[3] = .init(id: 4, text: "Last reply is still streaming…", isUser: true)
        update()
        check(copied(views[0]) == expectedCopy, "later streaming text cleared selection")
        sources[0] = .init(id: 0, text: "Earlier history grew before the selection", isUser: false)
        update()
        check(copied(views[0]) == expectedCopy, "earlier text growth moved message-relative selection")

        for percentage in [80, 150, 100] {
            style = .init(font: .systemFont(ofSize: 14 * CGFloat(percentage) / 100),
                          foreground: .labelColor, userForeground: .labelColor)
            update()
            check(copied(views[0]) == expectedCopy, "zoom cleared or moved cross-block selection")
            check(window.firstResponder === views[0], "zoom stole selection keyboard focus")
        }

        let other = MacConversationTextDocument()
        other.update(identity: ObjectIdentifier(NSObject()), sources: [.init(id: 1, text: "Other pane", isUser: false)], style: style) {
            NSAttributedString(string: $0.text, attributes: [.font: style.font])
        }
        let otherView = require(other.textView(for: 1) as? MacDirectMessageTextView, "missing other view")
        check(otherView.layoutManager !== views[0].layoutManager, "panes share a text network")
        otherView.setSelectedRange(NSRange(location: 0, length: 5))
        check(copied(views[0]) == expectedCopy, "another pane changed this selection")

        // Native text tables have their own paragraph geometry and remain isolated.
        let tableDocument = MacConversationTextDocument()
        let table = NSTextTable()
        table.numberOfColumns = 1
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                                startingColumn: 0, columnSpan: 1)]
        tableDocument.update(identity: ObjectIdentifier(owner), sources: [
            .init(id: 10, text: "Cell\n", isUser: false), .init(id: 11, text: "After table", isUser: false),
        ], style: style) { source in
            NSAttributedString(string: source.text, attributes: source.id == 10
                               ? [.font: style.font, .paragraphStyle: paragraph] : [.font: style.font])
        }
        for id in [10, 11] {
            let container = require(tableDocument.container(for: id), "missing table container")
            let layout = require(tableDocument.layout(for: id), "missing table layout")
            layout.ensureLayout(for: container)
            let range = layout.characterRange(
                forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil
            )
            let expected = require(tableDocument.range(for: id), "missing table range")
            check(range.location == 0 && range.length == expected.length, "table broke message boundaries")
        }
        // Exercise actual deallocation; retaining retired views masks native
        // selection/input-context lifetime defects. Keep another row alive.
        let recycled = MacConversationTextDocument()
        let recycledOwner = NSObject()
        func recycleUpdate(_ index: Int) {
            let nextStyle = MacConversationTextDocument.Style(
                font: .systemFont(ofSize: index.isMultiple(of: 2) ? 11.2 : 21),
                foreground: .labelColor, userForeground: .labelColor)
            recycled.update(identity: ObjectIdentifier(recycledOwner), sources: [
                .init(id: 1, text: "Recycled 中文 row \(index)", isUser: false),
                .init(id: 2, text: "Visible sibling", isUser: false)
            ], style: nextStyle) {
                NSAttributedString(string: $0.text, attributes: [.font: nextStyle.font])
            }
        }
        recycleUpdate(0)
        let sibling = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100),
                                 textContainer: recycled.container(for: 2))
        root.addSubview(sibling)
        for index in 0..<120 {
            weak var retired: NSTextView?
            autoreleasepool {
                let container = require(recycled.container(for: 1), "missing recycled container")
                let layout = require(recycled.layout(for: 1), "missing recycled layout")
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
                let view = MacDirectMessageTextView(frame: scroll.bounds, textContainer: container)
                view.document = recycled
                view.messageID = 1
                retired = view
                scroll.documentView = view
                root.addSubview(scroll)
                view.setSelectedRange(NSRange(location: 0, length: 3))
                layout.ensureLayout(for: container)
                check(window.makeFirstResponder(view), "could not focus recycled row")
                MacConversationTextDocument.retireTextView(view)
                check(window.firstResponder === sibling, "retired row kept keyboard focus")
                scroll.removeFromSuperview()
            }
            let retireDeadline = Date().addingTimeInterval(2)
            while retired != nil && Date() < retireDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            check(retired == nil, "retired row was retained")
            recycleUpdate(index + 1)
            sibling.setSelectedRange(NSRange(location: 0, length: 3))
        }
        // Product rows reuse a single native view per loaded block, and the
        // document owns only the currently loaded cohort (no global cache).
        let stable = require(recycled.textView(for: 1), "missing stable native row")
        check(stable === recycled.textView(for: 1), "native row was recreated")
        stable.setSelectedRange(NSRange(location: 0, length: 3))
        for index in 122..<242 {
            autoreleasepool {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
                scroll.documentView = recycled.textView(for: 1)
                root.addSubview(scroll)
                recycleUpdate(index)
                check(stable === recycled.textView(for: 1), "zoom replaced the native view")
                check(stable.selectedRange().length == 3, "row reuse cleared selection")
                scroll.removeFromSuperview()
            }
        }
        // Single-authority sizing matches the drawing container at every width and indent.
        for indent in [0.0, 18, 40] {
            for width in [220.0, 400, 760] {
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
                paragraph.lineSpacing = 4
                let measuredText = NSAttributedString(
                    string: String(repeating: "Some 中文 words with wrapping. ", count: 12),
                    attributes: [.font: style.font, .paragraphStyle: paragraph])
                let measuredDoc = MacConversationTextDocument()
                measuredDoc.update(identity: ObjectIdentifier(owner), sources: [
                    .init(id: 1, text: measuredText.string, isUser: false),
                    .init(id: 2, text: "Following", isUser: false)
                ], style: style) { $0.id == 1 ? measuredText : NSAttributedString(string: $0.text, attributes: [.font: style.font]) }
                let size = require(measuredDoc.size(for: 1, proposalWidth: width, font: style.font), "missing measured size")
                let measuredContainer = require(measuredDoc.container(for: 1), "missing measured container")
                let measuredLayout = require(measuredDoc.layout(for: 1), "missing measured layout")
                measuredLayout.ensureLayout(for: measuredContainer)
                let drawn = measuredLayout.usedRect(for: measuredContainer)
                check(drawn.maxY <= size.height + 0.5 && abs(drawn.maxY - size.height) < 1,
                      "Single-authority height mismatch: \(size) vs \(drawn), indent \(indent)")
            }
        }

        let tallText = NSAttributedString(string: String(repeating: "Long line\n", count: 8000),
                                          attributes: [.font: style.font])
        let tallEngine = MacSingleTextEngine()
        tallEngine.setText(tallText, font: style.font)
        let tallSize = tallEngine.size(forProposalWidth: 240, font: style.font)
        check(tallSize.height > 100_000,
              "Measurement canvas truncated a long message")

        // Replacing a representable must leave the retired mount powerless:
        // delayed layout/teardown cannot move or remove its replacement's text.
        let oldMount = MacMessageTextMount(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        let newMount = MacMessageTextMount(frame: NSRect(x: 0, y: 200, width: 300, height: 220))
        root.addSubview(oldMount)
        root.addSubview(newMount)
        oldMount.attach(stable)
        oldMount.layoutSubtreeIfNeeded()
        check(stable.frame.size == oldMount.bounds.size, "initial text mount failed layout")
        let selected = stable.selectedRange()
        newMount.attach(stable)
        newMount.layoutSubtreeIfNeeded()
        let replacementFrame = stable.frame
        oldMount.frame.size = NSSize(width: 90, height: 20)
        oldMount.needsLayout = true
        oldMount.layoutSubtreeIfNeeded()
        oldMount.releaseTextView()
        check(oldMount.textView == nil, "retired mount still owns replacement text")
        check(stable.superview === newMount && stable.frame == replacementFrame,
              "stale mount changed replacement text geometry or attachment")
        check(stable.selectedRange() == selected, "reattachment cleared native selection")
        newMount.frame.size = .zero
        newMount.needsLayout = true
        newMount.layoutSubtreeIfNeeded()
        check(stable.frame == replacementFrame, "zero-sized placement collapsed text layout")
        newMount.frame.size = NSSize(width: 450, height: 260)
        newMount.needsLayout = true
        newMount.layoutSubtreeIfNeeded()
        check(stable.frame.size == newMount.bounds.size, "current mount did not reflow")
        newMount.releaseTextView()
        check(stable.superview == nil, "active mount did not retire its text")
        oldMount.removeFromSuperview()
        newMount.removeFromSuperview()

        weak var pruned: NSTextView?
        let bounded = MacConversationTextDocument()
        autoreleasepool {
            bounded.update(identity: ObjectIdentifier(owner), sources: [.init(id: 1, text: "Removed", isUser: false)], style: style) {
                NSAttributedString(string: $0.text, attributes: [.font: style.font])
            }
            pruned = bounded.textView(for: 1)
            bounded.update(identity: ObjectIdentifier(owner), sources: [.init(id: 2, text: "Replacement", isUser: false)], style: style) {
                NSAttributedString(string: $0.text, attributes: [.font: style.font])
            }
            check(bounded.textView(for: 1) == nil, "removed block remains cached")
            _ = bounded.textView(for: 2)
        }
        let pruneDeadline = Date().addingTimeInterval(2)
        while pruned != nil && Date() < pruneDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(pruned == nil && bounded.textView(for: 1) == nil, "removed block's native view leaked")
        weak var released: NSTextView?
        weak var releasedDocument: MacConversationTextDocument?
        autoreleasepool {
            let temporary = MacConversationTextDocument()
            releasedDocument = temporary
            temporary.update(identity: ObjectIdentifier(owner), sources: [.init(id: 1, text: "Temporary", isUser: false)], style: style) {
                NSAttributedString(string: $0.text, attributes: [.font: style.font])
            }
            released = temporary.textView(for: 1)
        }
        check(releasedDocument == nil, "conversation owner leaked")
        // AppKit's initial text checking briefly retains a new text view until
        // the next run-loop turn, independently of the document's ownership.
        let deadline = Date().addingTimeInterval(2)
        while released != nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(released == nil, "conversation native-view cohort leaked")
        print("PASS native multi-block selection: Unicode/RTF Copy, history/streaming/zoom preservation, pane isolation, tables, 120 actual row deallocations, 120 stable-view reattachments, focus transfers and bounded cohort release")
    }
}
