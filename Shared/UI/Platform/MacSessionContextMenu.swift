#if os(macOS)
import AppKit

/// Native descendants ask their pane for session actions only when the
/// context click did not land on text. No global event interception is needed.
@MainActor
protocol MacSessionContextMenuProviding: AnyObject {
    func makeSessionContextMenu() -> NSMenu?
}

extension NSView {
    func paneSessionContextMenu() -> NSMenu? {
        var ancestor: NSView? = self
        while let view = ancestor {
            if let provider = view as? MacSessionContextMenuProviding,
               let menu = provider.makeSessionContextMenu() {
                // Keep session menus free of system AutoFill / Writing Tools plugin items.
                menu.allowsContextMenuPlugIns = false
                if #available(macOS 15.2, *) {
                    menu.automaticallyInsertsWritingToolsItems = false
                }
                return menu
            }
            ancestor = view.superview
        }
        return nil
    }
}
#endif
