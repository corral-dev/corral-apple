import AppKit
import SwiftUI
import Observation

@Observable @MainActor final class ComposerState {
    var text = ""
    var attachments: [DraftImageAttachment] = []
    var fileAttachments: [DraftFileAttachment] = []
    var revision = 0
    var sends = 0
    var followUps: [String] = []
    var recalls = 0
    var interfaceScale: CGFloat = 1.0
}

struct ComposerScreen: View {
    let state: ComposerState
    var body: some View {
        @Bindable var state = state
        VStack {
            Text("Incoming message revision \(state.revision)")
            Spacer()
            ComposerBar(text: $state.text, attachments: $state.attachments,
                        fileAttachments: $state.fileAttachments,
                        history: ["Older prompt", "Newest 中文🙂 prompt"],
                        showsFollowUpContextAction: true,
                        onSend: { _, _, _ in state.sends += 1 },
                        onFollowUp: { text, _, _ in state.followUps.append(text) },
                        onRecallQueued: {
                            guard let popped = state.followUps.popLast() else { return false }
                            state.text = popped
                            state.recalls += 1
                            return true
                        })
        }
        .padding()
        .environment(\.interfaceScale, state.interfaceScale)
    }
}

@main struct ComposerProbe {
    @MainActor static func main() {
        let inspect = CommandLine.arguments.contains("--inspect")
        NSApplication.shared.setActivationPolicy(inspect ? .accessory : .prohibited)
        let state = ComposerState()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Corral composer continuity verification"
        let host = NSHostingView(rootView: AnyView(ComposerScreen(state: state)))
        window.contentView = host
        // Never activate the app or move the user's pointer.
        window.orderBack(nil)
        defer { window.close() }
        let document = MacConversationTextDocument(), owner = NSObject()
        let style = MacConversationTextDocument.Style(font: .systemFont(ofSize: 14),
                                                      foreground: .labelColor, userForeground: .labelColor)
        var sources = [MacConversationTextDocument.Source(id: 1, text: "Streaming reply", isUser: false)]
        func render() {
            document.update(identity: ObjectIdentifier(owner), sources: sources, style: style) {
                NSAttributedString(string: $0.text, attributes: [.font: style.font])
            }
        }
        render()
        let message = NSTextView(frame: NSRect(x: 20, y: 130, width: 590, height: 80),
                                 textContainer: document.container(for: 1))
        message.isEditable = false
        host.addSubview(message)
        pump(host)
        guard let editor = MacComposerInputAnchor.textView(in: host) as? ComposerNSTextView,
              window.makeFirstResponder(editor) else { fatalError("No native composer") }
        pump(host)
        func replaceDraft(_ text: String) {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            pump(host)
            precondition(state.text == text, "Native edit failed to update the draft binding")
        }
        func refresh() {
            state.revision += 1
            // The streaming reply is the last source; earlier history may be
            // prepended during the run, so never assume index zero.
            sources[sources.count - 1] = .init(id: 1, text: "Streaming reply \(state.revision)", isUser: false)
            render()
            host.rootView = AnyView(ComposerScreen(state: state))
            pump(host)
        }
        func preserve(_ range: NSRange, label: String) {
            editor.setSelectedRange(range)
            pump(host)
            let text = editor.string
            for _ in 0..<8 {
                refresh()
                precondition(window.firstResponder === editor, "\(label): focus stolen")
                precondition(editor.string == text && state.text == text, "\(label): draft changed")
                precondition(editor.selectedRange() == range,
                             "\(label): caret moved from \(range) to \(editor.selectedRange())")
            }
            print("PASS \(label): \(range) after 8 production message updates")
        }
        replaceDraft("Draft 中文🙂 middle text")
        preserve(NSRange(location: (editor.string as NSString).length, length: 0), label: "end caret")
        preserve(NSRange(location: 6, length: 0), label: "middle caret")
        preserve(NSRange(location: 6, length: 4), label: "Unicode selection")
        sources.insert(.init(id: 0, text: "Earlier history", isUser: false), at: 0)
        render(); pump(host)
        precondition(editor.selectedRange() == NSRange(location: 6, length: 4), "Prepending history moved composer selection")
        replaceDraft("First line\nSecond 中文🙂 line\nThird line")
        preserve(NSRange(location: 16, length: 0), label: "multiline caret")
        editor.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: editor.selectedRange())
        pump(host)
        let marked = editor.markedRange(), caret = editor.selectedRange(), composed = editor.string
        for _ in 0..<8 {
            refresh()
            precondition(editor.hasMarkedText() && editor.markedRange() == marked, "Message update ended IME composition")
            precondition(editor.selectedRange() == caret && editor.string == composed, "Message update moved IME caret")
        }
        editor.unmarkText()
        print("PASS Chinese IME marked text after 8 production message updates")
        replaceDraft("Draft kept")
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                fatalError("No native key event")
            }
            window.sendEvent(event)
            pump(host)
        }
        key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.function, .numericPad])
        precondition(state.text == "Newest 中文🙂 prompt", "Up did not recall newest prompt")
        precondition(editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0), "Recall caret is not at end")
        key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.function, .numericPad])
        precondition(state.text == "Draft kept", "Down did not restore draft")
        editor.setSelectedRange(NSRange(location: 5, length: 0)); pump(host)
        key(36, "\r", modifiers: [.shift])
        precondition(state.text == "Draft\n kept" && editor.selectedRange() == NSRange(location: 6, length: 0),
                     "Shift-Return did not insert at native caret")
        precondition(state.sends == 0, "Inspection sent a prompt")
        print("PASS native Up/Down recall, draft restoration and Shift-Return; no sends")

        // Verify Option+Return follow-up trigger, IME composition guard, and Option+Up queue recall.
        replaceDraft("Follow up 中文🙂")
        key(36, "\r", modifiers: [.option])
        precondition(state.followUps == ["Follow up 中文🙂"] && state.text.isEmpty && state.sends == 0,
                     "Option+Return did not trigger follow-up cleanly")
        editor.setMarkedText("待确认", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: editor.selectedRange())
        pump(host)
        key(36, "\r", modifiers: [.option])
        precondition(state.followUps == ["Follow up 中文🙂"], "Option+Return must not bypass active IME marked text")
        editor.unmarkText()
        replaceDraft("")
        key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.option, .function, .numericPad])
        precondition(state.followUps.isEmpty && state.text == "Follow up 中文🙂" && state.recalls == 1,
                     "Option+Up did not recall the last queued follow-up item")
        replaceDraft("")
        print("PASS Option+Return follow-up trigger, IME guard, and Option+Up recall")

        // Verify TextKit 1 wrapping of mixed CJK + ASCII timestamps across 100%, 120%, and 140% zoom has zero blank line gaps.
        let repro = "允许 tw-1 混跑，毕竟不能浪费资源，然后没有装zerotier这些事情你可以帮我做好。caozc.com到期时间是2029-09-05 19:22:00，然后caozc.top到期时间是2027-09-26 12:11:55，计划到期之后就不再续费了。"
        for fontSize in [CGFloat(14.0), CGFloat(16.8), CGFloat(19.6)] {
            editor.font = .systemFont(ofSize: fontSize)
            editor.applyTypingAttributes(font: .systemFont(ofSize: fontSize), textColor: .labelColor)
            replaceDraft(repro)
            precondition(editor.layoutManager != nil && editor.textContainer != nil, "Expected TextKit 1 stack")
            for width in stride(from: CGFloat(640), through: 760, by: 2) {
                let measured = editor.measuredContentHeight(forWidth: width)
                guard let lm = editor.layoutManager, let tc = editor.textContainer else { fatalError("Missing TextKit 1") }
                var rects: [CGRect] = []
                let glyphs = lm.glyphRange(for: tc)
                lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    rects.append(rect)
                }
                precondition(rects.count >= 2, "Expected multi-line wrap at width \(width), fontSize \(fontSize)")
                for i in 1..<rects.count {
                    let gap = rects[i].minY - rects[i - 1].maxY
                    precondition(gap >= -1.0 && gap <= 4.0, "Unexpected blank line gap \(gap) at width \(width), fontSize \(fontSize)")
                }
                let expectedMaxY = ceil(rects.last?.maxY ?? 0)
                precondition(abs(measured.contentHeight - expectedMaxY) <= 2.0,
                             "Measured height \(measured.contentHeight) mismatches layout \(expectedMaxY) at width \(width)")
            }
        }
        editor.font = .systemFont(ofSize: 16.8)
        editor.applyTypingAttributes(font: .systemFont(ofSize: 16.8), textColor: .labelColor)

        // Verify IME marked-text callback & typingAttributes survival after clearing draft on send.
        replaceDraft("")
        var markedEvents: [Bool] = []
        let prevMarkedHandler = editor.onMarkedTextChange
        editor.onMarkedTextChange = {
            markedEvents.append($0)
            prevMarkedHandler?($0)
        }
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        precondition(editor.hasMarkedText() && markedEvents.last == true, "Expected marked text active")
        editor.unmarkText()
        precondition(!editor.hasMarkedText() && markedEvents.last == false, "Expected marked text cleared")
        editor.onMarkedTextChange = prevMarkedHandler
        replaceDraft("line1\nline2")
        state.text = ""
        pump(host)
        let typingFont = editor.typingAttributes[.font] as? NSFont
        precondition(abs((typingFont?.pointSize ?? 0) - 14.0) < 0.2,
                     "Typing font should keep ComposerBar font (14.0pt) after clear, got \(typingFont?.pointSize ?? 0)")
        let afterClear = editor.measuredContentHeight(forWidth: 680)
        precondition(abs(afterClear.contentHeight - afterClear.lineHeight) <= 2.0,
                     "Cleared composer should shrink back to single line, got \(afterClear)")

        // Verify zoom font parity (100% / 120% / 140%) and zero height shrink across typing lifecycle.
        for (scale, expectedPt) in [(CGFloat(1.0), CGFloat(14.0)), (CGFloat(1.2), CGFloat(16.8)), (CGFloat(1.4), CGFloat(19.6))] {
            state.interfaceScale = scale
            state.text = ""
            pump(host)
            precondition(abs((editor.font?.pointSize ?? 0) - expectedPt) < 0.05,
                         "Composer font size at scale \(scale) should be \(expectedPt), got \(editor.font?.pointSize ?? 0)")
            precondition(!editor.placeholderText.isEmpty, "Composer placeholder should be set natively")
            let expectedBubblePt = Typography.sessionUIFont(.bubbleBody, scale: 1.0 * scale).pointSize
            precondition(abs((editor.font?.pointSize ?? 0) - expectedBubblePt) < 0.05,
                         "Composer font \(editor.font?.pointSize ?? 0) must match bubble font \(expectedBubblePt)")

            guard let scrollView = editor.enclosingScrollView else { fatalError("Missing NSScrollView") }
            let hEmpty = scrollView.frame.height
            precondition(hEmpty > 0, "Expected positive empty composer height at scale \(scale)")

            editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
            pump(host)
            let hASCII = scrollView.frame.height
            precondition(abs(hASCII - hEmpty) < 0.5,
                         "Composer height changed on ASCII at scale \(scale): empty=\(hEmpty) ascii=\(hASCII)")

            replaceDraft("")
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
            pump(host)
            let hIME = scrollView.frame.height
            precondition(abs(hIME - hEmpty) < 0.5,
                         "Composer height changed on IME at scale \(scale): empty=\(hEmpty) ime=\(hIME)")

            editor.insertText("你好", replacementRange: editor.markedRange())
            pump(host)
            let hCJK = scrollView.frame.height
            precondition(abs(hCJK - hEmpty) < 0.5,
                         "Composer height changed on CJK at scale \(scale): empty=\(hEmpty) cjk=\(hCJK)")
            let storedFont = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            precondition(abs((storedFont?.pointSize ?? 0) - expectedPt) < 0.2,
                         "Stored text font pointSize should be \(expectedPt), got \(storedFont?.pointSize ?? 0)")

            editor.insertText("🙂", replacementRange: editor.selectedRange())
            pump(host)
            let hEmoji = scrollView.frame.height
            precondition(abs(hEmoji - hEmpty) < 0.5,
                         "Composer height changed on emoji at scale \(scale): empty=\(hEmpty) emoji=\(hEmoji)")

            // Grow to 4 lines then clear back to empty and confirm exact restore to hEmpty.
            replaceDraft("Line 1\nLine 2\nLine 3\nLine 4")
            precondition(scrollView.frame.height > hEmpty + 20, "Expected multi-line growth before clear check")
            state.text = ""
            pump(host)
            let hCleared = scrollView.frame.height
            precondition(abs(hCleared - hEmpty) < 0.5,
                         "Composer height changed after clear at scale \(scale): empty=\(hEmpty) cleared=\(hCleared)")
            precondition(abs(editor.frame.height - hCleared) < 0.5,
                         "Document textView frame height \(editor.frame.height) must shrink back to \(hCleared)")
        }
        state.interfaceScale = 1.2
        pump(host)
        print("PASS zoom font parity (14.0/16.8/19.6pt) and zero height delta across empty/ASCII/IME/CJK/emoji/clear")

        // Verify Finder fileURL-first pasteboard priority (.pdf, .svg, .zip, .png), screenshot image paste, and rich text fallback.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let pdfURL = tmpDir.appendingPathComponent("report.pdf")
        let svgURL = tmpDir.appendingPathComponent("diagram.svg")
        let zipURL = tmpDir.appendingPathComponent("bundle.zip")
        try? Data("%PDF-1.4\ntest".utf8).write(to: pdfURL)
        try? Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8).write(to: svgURL)
        try? Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]).write(to: zipURL)

        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects([pdfURL as NSURL])
        board.setString("report.pdf", forType: .string)
        board.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)
        precondition(ComposerPasteboard.classify(board) == .fileURLs([pdfURL]), "Finder fileURL must beat string/tiff")
        precondition(ComposerPasteboard.canPaste(from: board), "fileURL pasteboard must validate Paste")
        replaceDraft("")
        state.attachments = []
        state.fileAttachments = []
        precondition(editor.handlePasteboard(board), "PDF paste should succeed")
        pump(host)
        precondition(state.fileAttachments.map(\.name) == ["report.pdf"] && state.text.isEmpty,
                     "PDF paste should attach file without inserting filename string")

        // SVG and ZIP must also attach losslessly as DraftFileAttachment (not rasterized).
        for url in [svgURL, zipURL] {
            board.clearContents()
            board.writeObjects([url as NSURL])
            precondition(editor.handlePasteboard(board), "File paste \(url.lastPathComponent) should succeed")
            pump(host)
        }
        precondition(state.fileAttachments.map(\.name) == ["report.pdf", "diagram.svg", "bundle.zip"],
                     "Expected .pdf, .svg, .zip file attachments, got \(state.fileAttachments.map(\.name))")

        // PNG fileURL and raw PNG data both attach as image thumbnails.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let pngData = rep.representation(using: .png, properties: [:])!
        let pngURL = tmpDir.appendingPathComponent("shot.png")
        try? pngData.write(to: pngURL)
        board.clearContents()
        board.writeObjects([pngURL as NSURL])
        precondition(editor.handlePasteboard(board), "PNG fileURL paste should succeed")
        pump(host)
        precondition(state.attachments.count == 1, "PNG fileURL should add image attachment")

        board.clearContents()
        board.setData(pngData, forType: .png)
        precondition(ComposerPasteboard.canPaste(from: board), "Image-only pasteboard must validate Paste")
        precondition(editor.handlePasteboard(board), "PNG paste should succeed")
        pump(host)
        precondition(state.attachments.count == 2, "PNG paste should add second image attachment")

        board.clearContents()
        board.setString("plain\r\nline2", forType: .string)
        board.setString("<p>plain</p>", forType: .html)
        precondition(editor.handlePasteboard(board), "HTML+string text paste should insert normalized text")
        pump(host)
        precondition(state.text == "plain\nline2", "Expected normalized text paste, got \(state.text)")

        print("PASS TextKit 1 mixed-script wrap (0 blank gap) and Finder/image/text pasteboard handling")
        PaneInteractionProbe.run()
        if inspect {
            replaceDraft("Keep typing 中文🙂 right here while messages arrive")
            preserve(NSRange(location: 12, length: 0), label: "visible native composer")
            for _ in 0..<60 { refresh() }
        }
    }

    @MainActor static func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
