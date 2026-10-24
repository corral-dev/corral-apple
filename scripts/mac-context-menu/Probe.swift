import AppKit
import SwiftTerm

@MainActor
private final class SessionMenuHost: NSView, MacSessionContextMenuProviding {
    let sessionName: String
    init(_ name: String) {
        sessionName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    }
    required init?(coder: NSCoder) { nil }
    func makeSessionContextMenu() -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: sessionName, action: nil, keyEquivalent: "")
        return menu
    }
}

@main
struct ContextMenuProbe {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor static func event(_ point: NSPoint, in view: NSView) -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown,
            location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0) else { fatalError("event description") }
        return event // Queried directly; never posted or sent to the application.
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = SessionMenuHost("First pane")
        window.contentView = host
        let text = MacDirectMessageTextView(frame: NSRect(x: 20, y: 250, width: 600, height: 200))
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 12, height: 8)
        text.font = .systemFont(ofSize: 16)
        text.string = "English 中文🙂\nSecond line"
        host.addSubview(text)
        guard let layout = text.layoutManager, let container = text.textContainer else { fatalError("TextKit") }
        layout.ensureLayout(for: container)
        for index in [0, 8, 10] {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let point = NSPoint(x: rect.midX + text.textContainerOrigin.x,
                                y: rect.midY + text.textContainerOrigin.y)
            let click = event(point, in: text)
            require(text.isText(at: click), "English/CJK/emoji text remains a text target")
            require(text.menu(for: click)?.items.contains { $0.action == #selector(NSText.copy(_:)) } == true,
                    "native text context menu retains Copy")
        }
        text.setSelectedRange(NSRange(location: 0, length: 7))
        for point in [NSPoint(x: 580, y: 15), NSPoint(x: 200, y: 180), NSPoint(x: 2, y: 2)] {
            let click = event(point, in: text)
            require(!text.isText(at: click), "padding/trailing/below-text space is blank")
            require(text.menu(for: click)?.items.first?.title == "First pane", "blank uses its pane, despite selection")
        }
        text.string = ""
        require(text.menu(for: event(NSPoint(x: 30, y: 20), in: text))?.items.first?.title == "First pane",
                "empty message routes to session")

        let terminal = StreamTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        terminal.resize(cols: 80, rows: 24)
        terminal.contextMenuCellSize = CGSize(width: 8, height: 10)
        terminal.feedFromHost(Data("Text中文🙂".utf8))
        host.addSubview(terminal)
        for col in [0, 4, 5, 6, 7, 8, 9] {
            let point = NSPoint(x: CGFloat(col) * 8 + 4, y: terminal.bounds.height - 5)
            require(terminal.isText(at: point), "terminal English and both halves of wide glyphs are text")
            let menu = terminal.menu(for: event(point, in: terminal))
            require(menu?.items.map(\.action) == [#selector(terminal.copy(_:)), #selector(terminal.paste(_:)), #selector(terminal.selectAll(_:))],
                    "terminal uses native Copy/Paste/Select All actions")
        }
        terminal.selectAll(nil)
        let blank = event(NSPoint(x: 500, y: 20), in: terminal)
        require(terminal.menu(for: blank)?.items.first?.title == "First pane", "terminal blank ignores selection elsewhere")
        let second = SessionMenuHost("Second pane")
        host.addSubview(second)
        terminal.removeFromSuperview()
        second.addSubview(terminal)
        require(terminal.menu(for: blank)?.items.first?.title == "Second pane", "nearest pane owns the menu")
        require(terminal.onPaste == nil, "menu queries send no agent input")
        print("PASS: native text menus; English/CJK/emoji; text insets; trailing/below/empty space; terminal wide cells; selection elsewhere; pane isolation")
    }
}
