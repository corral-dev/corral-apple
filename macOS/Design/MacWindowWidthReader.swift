import AppKit
import SwiftUI

/// Reports the host window's content width. `NavigationSplitView` does not
/// expose the window's own width through its content geometry, and the
/// sidebar fit rule needs the space the window actually has.
struct MacWindowWidthReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ObserverView else { return }
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var lastWidth: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification,
                object: window
            )
            report()
        }

        @objc private func windowDidResize() {
            report()
        }

        func report() {
            guard let width = window?.contentView?.bounds.width, width > 0, width != lastWidth else { return }
            lastWidth = width
            onChange?(width)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
