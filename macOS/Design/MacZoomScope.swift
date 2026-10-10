import AppKit
import SwiftUI

/// Apply to every scene root so sheets/popovers inherit the same preference.
struct MacZoomScope: ViewModifier {
    let zoom: MacInterfaceZoom
    func body(content: Content) -> some View {
        content
            .environment(zoom)
            .environment(\.interfaceScale, zoom.scale)
            .task { MacZoomKeyAlias.shared.configure(zoom: zoom) }
            .onChange(of: zoom.percentage) { _, _ in MacZoomKeyAlias.shared.install() }
    }
}

/// Scale product content inside native containers. The scene scope must not
/// replace the contextual font/control size of system toolbars or tab chrome.
struct MacZoomContent: ViewModifier {
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content
            .interfaceControlSize(.regular)
            .font(Font.body.scaled(by: scale))
    }
}

struct MacZoomCommands: Commands {
    let zoom: MacInterfaceZoom
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("mac.zoom.in") { zoom.increase() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!zoom.canIncrease)
            Button("mac.zoom.out") { zoom.decrease() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!zoom.canDecrease)
            Button("mac.zoom.reset") { zoom.reset() }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}

/// Keep one visible native Zoom In command while supporting unshifted equals.
/// SwiftUI may rebuild menus when a window changes; reconcile the native alias
/// after structural notifications instead of intercepting text or terminal keys.
@MainActor
private final class MacZoomKeyAlias: NSObject, NSMenuItemValidation {
    static let shared = MacZoomKeyAlias()
    private weak var zoom: MacInterfaceZoom?
    private var observers: [NSObjectProtocol] = []
    private lazy var alias: NSMenuItem = {
        let item = NSMenuItem(title: String(localized: "mac.zoom.in"), action: #selector(increase), keyEquivalent: "=")
        item.target = self
        item.keyEquivalentModifierMask = .command
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }()

    func configure(zoom: MacInterfaceZoom) {
        self.zoom = zoom
        if observers.isEmpty {
            for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in Self.shared.install() }
                })
            }
        }
        install()
    }

    func install() {
        guard let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.keyEquivalent == "+" && $0.keyEquivalentModifierMask.contains(.command) }
        }) else { return }
        alias.isEnabled = zoom?.canIncrease == true
        guard !menu.items.contains(where: { $0 === alias }) else { return }
        alias.menu?.removeItem(alias)
        menu.addItem(alias)
    }

    @objc private func increase() { zoom?.increase() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { zoom?.canIncrease == true }
}

/// Native geometry changes may hand selection focus back to the window. Restore
/// the same component only while no other control has claimed the keyboard.
@MainActor
struct MacZoomFocusSnapshot {
    weak var window: NSWindow?
    weak var textView: NSTextView?

    static func capture() -> Self? {
        guard let window = NSApp?.keyWindow ?? NSApp?.windows.first(where: {
            $0.isVisible && ($0.firstResponder as? NSTextView)?.isEditable == false
        }), let view = window.firstResponder as? NSTextView,
           !view.isEditable, view.isSelectable, view.selectedRange().length > 0 else { return nil }
        return Self(window: window, textView: view)
    }

    func restoreAfterLayout() {
        Task { @MainActor [weak window, weak textView] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(25))
                guard let window, let textView else { return }
                if window.firstResponder === textView { continue }
                guard window.firstResponder === window || window.firstResponder == nil else { return }
                guard textView.window === window else { continue }
                window.makeFirstResponder(textView)
            }
        }
    }
}
