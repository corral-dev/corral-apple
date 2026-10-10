#if DEBUG
import AppKit

/// Exercises native menu routing and the actual host-backed client without
/// pointer automation or sending a draft. Bitmap exports are app rendering,
/// not WindowServer screenshots or proof of system chrome appearance.
@MainActor
enum MacZoomInspection {
    static func run(zoom: MacInterfaceZoom, workspace: MacWorkspace, feed: HostSessionFeed,
                    showSettings: @MainActor () -> Void) async {
        guard let path = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_ZOOM_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<80 where feed.listStore.windowSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let sessions = feed.listStore.windowSessions
        guard let key = sessions.first?.key else {
            write(["error": "No host sessions available"], to: directory)
            return
        }
        let previousPercentage = zoom.percentage
        let previousKeys = workspace.paneKeys
        let previousFocus = workspace.focusedKey
        let previousBoard = workspace.showingBoard
        let previousModes = Dictionary(uniqueKeysWithValues: sessions.prefix(4).map { ($0.key, workspace.mode(for: $0.key)) })
        defer {
            zoom.setPercentage(previousPercentage)
            for (key, mode) in previousModes { workspace.setMode(mode, for: key) }
            workspace.inspectionRestoreWorkspace(keys: previousKeys, focus: previousFocus, board: previousBoard)
        }
        workspace.restorePanes([key])
        workspace.setMode(.chat, for: key)
        await settle()
        guard let window = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible }),
              let content = window.contentView else {
            write(["error": "No main window"], to: directory)
            return
        }
        var checks: [String: Any] = [:]
        let originalResponder = window.firstResponder
        defer { window.makeFirstResponder(originalResponder) }
        zoom.reset()
        await settle()
        let texts = descendants(content).compactMap { $0 as? NSTextView }
        checks["nativeTextViews"] = texts.count
        let selectionCandidates = texts.filter {
            !$0.isEditable && $0.isSelectable && ($0.string as NSString).length > 12
                && !$0.visibleRect.isEmpty && $0.window === window
        }
        if let text = selectionCandidates.max(by: {
            content.bounds.insetBy(dx: 0, dy: 120).intersection($0.convert($0.visibleRect, to: content)).height
                < content.bounds.insetBy(dx: 0, dy: 120).intersection($1.convert($1.visibleRect, to: content)).height
        }), let layout = text.layoutManager, let container = text.textContainer {
            let original = text.selectedRange()
            layout.ensureLayout(for: container)
            let visibleBounds = text.visibleRect.intersection(text.convert(content.bounds.insetBy(dx: 0, dy: 120), from: content))
            let visible = visibleBounds.insetBy(dx: 0, dy: visibleBounds.height * 0.4)
                .offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
            let blockRange = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: visible, in: container), actualGlyphRange: nil)
            checks["selectionVisibleFrameBefore"] = NSStringFromRect(text.convert(text.visibleRect, to: content))
            let range = NSRange(location: blockRange.location + min(1, blockRange.length),
                                length: min(10, max(0, blockRange.length - 1)))
            checks["selectionFocusInstalled"] = window.makeFirstResponder(text)
            text.setSelectedRange(range)
            await settle()
            checks["selectionFocusBeforeZoom"] = window.firstResponder === text
            checks["commandEqualsFromSelection"] = shortcut("=", window: window) && zoom.percentage == 110
            await settle()
            let current = descendants(content).compactMap { $0 as? NSTextView }.filter { $0.layoutManager === layout }
            checks["selectionPreserved"] = current.contains { $0.selectedRange() == range }
            checks["selectionVisibleFrameAfter"] = NSStringFromRect(text.convert(text.visibleRect, to: content))
            checks["selectionFocusPreserved"] = (window.firstResponder as? NSTextView)?.layoutManager === layout
            checks["responderAfterSelectionZoom"] = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            let plusHandled = shortcut("+", flags: [.command, .shift], window: window)
            await settle()
            checks["commandPlusFromSelection"] = plusHandled && zoom.percentage == 120
            let minusHandled = shortcut("-", window: window)
            await settle()
            checks["commandMinusFromSelection"] = minusHandled && zoom.percentage == 110
            let resetHandled = shortcut("0", flags: [.command, .option], window: window)
            await settle()
            checks["resetFromSelection"] = resetHandled && zoom.percentage == 100
            descendants(content).compactMap { $0 as? NSTextView }
                .first(where: { $0.layoutManager === layout && !$0.visibleRect.isEmpty })?
                .setSelectedRange(original)
        }
        workspace.requestKeyFocus(key)
        await settle()
        checks["composerResponderClass"] = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        let editor = (window.firstResponder as? NSTextView).flatMap { $0.isEditable ? $0 : nil }
            ?? descendants(content).compactMap { $0 as? NSTextView }.first(where: { $0.isEditable })
        if let editor {
            // Clear only the exact diagnostic sentinel left by an interrupted run.
            let original = editor.string == "Zoom draft 中文" ? "" : editor.string
            let originalSelection = editor.selectedRange()
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText("Zoom draft 中文", replacementRange: editor.selectedRange())
            checks["commandEqualsFromComposer"] = shortcut("=", window: window) && zoom.percentage == 110
            await settle()
            checks["draftPreserved"] = editor.string == "Zoom draft 中文"
            checks["composerFocusPreserved"] = window.firstResponder === editor
            // Native marked text models an in-progress input-method composition.
            editor.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
            let marked = editor.markedRange()
            zoom.setPercentage(150)
            await settle()
            checks["markedTextPreserved"] = editor.hasMarkedText() && editor.markedRange() == marked
            editor.unmarkText()
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(original, replacementRange: editor.selectedRange())
            editor.setSelectedRange(NSRange(location: min(originalSelection.location, (original as NSString).length), length: 0))
            await settle()
            checks["draftRestored"] = editor.string == original
        }
        checks["menu"] = menuItems(NSApp.mainMenu).filter { ["+", "=", "-", "0"].contains($0["key"] as? String ?? "") }
        var layouts: [[String: Any]] = []
        for count in [1, min(4, sessions.count)] {
            let keys = Array(sessions.prefix(count).map(\.key))
            workspace.restorePanes(keys)
            for key in keys { workspace.setMode(.chat, for: key) }
            for percentage in [80, 100, 150] {
                zoom.setPercentage(percentage)
                await settle()
                let exported = export(content, to: directory.appendingPathComponent("chat-\(count)-\(percentage).png"))
                layouts.append(["panes": count, "percentage": percentage, "bitmapExported": exported,
                                "windowWidth": content.bounds.width,
                                "paneWidths": keys.compactMap { workspace.paneFrames[$0]?.width }])
            }
        }
        // Subscribe to an already-hosted session. No input is sent to it.
        if let hosted = sessions.first(where: { $0.hosted }) {
            let mode = workspace.mode(for: hosted.key)
            workspace.restorePanes([hosted.key])
            workspace.setMode(.terminal, for: hosted.key)
            zoom.reset()
            for _ in 0..<60 {
                await settle()
                if TerminalHostView.inspectionLatest?.inspectionFirstReset != nil { break }
            }
            var terminalChecks: [[String: Any]] = []
            for percentage in [80, 100, 150] {
                zoom.setPercentage(percentage)
                await settle()
                guard let terminal = TerminalHostView.inspectionLatest, terminal.window === window else { continue }
                checks["commandEqualsFromTerminal"] = shortcut("=", window: window) && zoom.percentage == min(percentage + 10, 150)
                zoom.setPercentage(percentage)
                await settle()
                terminalChecks.append(["percentage": percentage, "fontSize": terminal.inspectionFontSize,
                                       "snapshotReceived": terminal.inspectionFirstReset != nil,
                                       "nonemptyRows": terminal.inspectionVisibleRows,
                                       "focusRetained": terminal.inspectionHasKeyboardFocus,
                                       "bottomVisible": terminal.inspectionBottomVisible,
                                       "bitmapExported": export(content, to: directory.appendingPathComponent("terminal-\(percentage).png"))])
            }
            workspace.setMode(mode, for: hosted.key)
            checks["terminal"] = terminalChecks
        }
        showSettings()
        await settle()
        if let settings = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil }),
           let settingsContent = settings.contentView {
            var settingsChecks: [[String: Any]] = []
            for percentage in [80, 150] {
                zoom.setPercentage(percentage)
                await settle()
                if percentage == 80 {
                    checks["commandEqualsFromSettings"] = shortcut("=", window: settings) && zoom.percentage == 90
                    zoom.setPercentage(percentage)
                    await settle()
                }
                let controls = descendants(settingsContent).compactMap { $0 as? NSPopUpButton }
                settingsChecks.append(["percentage": percentage,
                    "nativePickerTitles": controls.map { $0.title },
                    "bitmapExported": export(settingsContent, to: directory.appendingPathComponent("settings-\(percentage).png"))])
            }
            checks["settings"] = settingsChecks
            settings.close()
        }
        checks["layouts"] = layouts
        checks["renderingMethod"] = "NSView.cacheDisplay; not a desktop screenshot"
        write(checks, to: directory)
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(700)) }

    private static func shortcut(_ key: String, flags: NSEvent.ModifierFlags = .command, window: NSWindow) -> Bool {
        NSApp.mainMenu?.update()
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: key == "-" ? 27 : (key == "0" ? 29 : 24)) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private static func descendants(_ root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants($0) }
    }

    private static func menuItems(_ menu: NSMenu?) -> [[String: Any]] {
        (menu?.items ?? []).flatMap { item in
            [["title": item.title, "key": item.keyEquivalent, "flags": item.keyEquivalentModifierMask.rawValue,
              "hidden": item.isHidden, "enabled": item.isEnabled]] + menuItems(item.submenu)
        }
    }

    private static func export(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }

    private static func write(_ result: [String: Any], to directory: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
}
#endif
