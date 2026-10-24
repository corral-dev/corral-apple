import AppKit
import SwiftUI

/// Observe the mounted native List's own scroll view. This adds no control,
/// event handler or substitute list; AppKit owns scrolling and clipping.
struct MacSearchScrollBookmark: NSViewRepresentable {
    let state: MacSearchState

    func makeNSView(context: Context) -> BookmarkView { BookmarkView() }
    func updateNSView(_ view: BookmarkView, context: Context) {
        view.state = state
        view.attach()
    }

    final class BookmarkView: NSView {
        var state: MacSearchState?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, let scroll = self.enclosingScrollView else { return }
                self.state?.attachScroll(scroll)
            }
        }
    }
}
