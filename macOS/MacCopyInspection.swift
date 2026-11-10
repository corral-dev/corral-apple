#if DEBUG
import AppKit

/// Same-window native Copy acceptance, without pointer or external key injection.
@MainActor
enum MacCopyInspection {
    static func run(key: String, workspace: MacWorkspace) async {
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectPathLink"),
           ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == key {
            await clickPathLink()
            return
        }
        let acrossBlocks = ProcessInfo.processInfo.arguments.contains("-CorralInspectCrossBlockCopy")
        guard acrossBlocks || ProcessInfo.processInfo.arguments.contains("-CorralInspectCopy"),
              ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == key else { return }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" }),
                  let content = window.contentView, let frame = workspace.paneFrames[key] else { continue }
            let texts = descendants(content).compactMap { $0 as? NSTextView }.filter { text in
                guard !text.isEditable, text.isSelectable, !text.string.isEmpty else { return false }
                let rect = text.convert(text.visibleRect, to: nil)
                return !rect.isEmpty && frame.contains(CGPoint(x: rect.midX, y: content.bounds.height - rect.midY))
            }
            guard let text = texts.max(by: { $0.string.count < $1.string.count }) else { continue }
            let previousResponder = window.firstResponder
            let previousRange = text.selectedRange()
            let pasteboard = NSPasteboard.general
            let saved = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            text.setSelectedRange(NSRange(location: 0, length: 0))
            let tookFocus = window.makeFirstResponder(text)
            let serial = workspace.keyFocusSerial
            workspace.claimKeysAfterClick(in: key, window: window)
            let keptStart = workspace.keyFocusSerial == serial && window.firstResponder === text
            let range: NSRange
            var linkedBlocks = 0
            if acrossBlocks, let layout = text.layoutManager {
                let visibleRanges = texts.filter { $0.layoutManager === layout }.compactMap { view -> NSRange? in
                    guard let container = view.textContainer else { return nil }
                    layout.ensureLayout(for: container)
                    return layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
                }.sorted { $0.location < $1.location }
                linkedBlocks = visibleRanges.count
                guard visibleRanges.count > 1 else { continue }
                let lower = visibleRanges[0].location + min(2, visibleRanges[0].length)
                let upper = visibleRanges[1].location + min(12, visibleRanges[1].length)
                range = NSRange(location: lower, length: upper - lower)
            } else {
                range = NSRange(location: 0, length: min(12, (text.string as NSString).length))
            }
            text.setSelectedRange(range)
            workspace.claimKeysAfterClick(in: key, window: window)
            let keptRange = workspace.keyFocusSerial == serial && window.firstResponder === text
            let expected = (text.string as NSString).substring(with: range)
            let event = acrossBlocks ? nil : NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)
            NSApp.mainMenu?.update()
            let shortcut = event.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
            let shortcutCopied = shortcut && pasteboard.string(forType: .string) == expected
            var nativeCopied = shortcutCopied
            if !nativeCopied {
                let sent = NSApp.sendAction(#selector(NSText.copy(_:)), to: window.firstResponder, from: nil)
                nativeCopied = sent && pasteboard.string(forType: .string) == expected
            }
            let changed = pasteboard.changeCount
            let result: [String: Any] = ["tookFocus": tookFocus, "keptSelectionStart": keptStart,
                "keptSelectionRange": keptRange, "shortcutHandled": shortcut,
                "shortcutCopied": shortcutCopied, "nativeCopyMatchedSelection": nativeCopied,
                "messageLength": text.string.count, "selectionLength": range.length,
                "crossBlock": acrossBlocks, "linkedVisibleBlocks": linkedBlocks]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-copy.json"))
            }
            // Keep selection on screen briefly for a capture, then restore the app.
            try? await Task.sleep(for: .seconds(6))
            if pasteboard.changeCount == changed {
                let items = saved.map { data in
                    let item = NSPasteboardItem()
                    for (type, value) in data { item.setData(value, forType: type) }
                    return item
                }
                pasteboard.clearContents()
                pasteboard.writeObjects(items)
            }
            text.setSelectedRange(previousRange)
            window.makeFirstResponder(previousResponder)
            return
        }
        try? "{\"error\":\"No visible message text\"}".write(toFile: "/tmp/corral-mac-copy.json", atomically: true, encoding: .utf8)
    }

    /// `-CorralInspectPathLink` + `CORRAL_INSPECTION_PATH_LINK=<visible link text>`:
    /// finds that path link in the shown conversation and clicks it through the
    /// text view's own `clicked(onLink:at:)`, the same entry a pointer click uses.
    /// Writes the links found and the clicked target to /tmp/corral-mac-path-link.json.
    private static func clickPathLink() async {
        let wanted = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PATH_LINK"] ?? ""
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Corral" }),
                  let content = window.contentView else { continue }
            var found: [String: String] = [:]
            var hit: (NSTextView, Any, Int)?
            for text in descendants(content).compactMap({ $0 as? NSTextView }) {
                guard let storage = text.textStorage, storage.length > 0 else { continue }
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    guard let url = value as? URL, url.isFileURL else { return }
                    let label = (storage.string as NSString).substring(with: range)
                    found[label] = url.path
                    if label == wanted, hit == nil { hit = (text, value as Any, range.location) }
                }
            }
            guard !found.isEmpty else { continue }
            if let (text, link, index) = hit { text.clicked(onLink: link, at: index) }
            let result: [String: Any] = ["links": found, "clicked": hit != nil ? found[wanted] ?? "" : ""]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-path-link.json"))
            }
            return
        }
    }

    private static func descendants(_ root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants($0) }
    }
}
#endif
