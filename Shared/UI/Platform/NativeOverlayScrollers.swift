#if os(macOS)
import AppKit
#endif
import SwiftUI

extension View {
    /// Apply inside scroll content or a List/Form row, where the native
    /// enclosingScrollView is public and unambiguous.
    func nativeOverlayScrollers() -> some View {
        #if os(macOS)
        background {
            NativeOverlayScrollerConfiguration()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct NativeOverlayScrollerConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeOverlayScrollerView {
        NativeOverlayScrollerView()
    }

    func updateNSView(_ view: NativeOverlayScrollerView, context: Context) {
        view.applyOverlayStyle()
    }
}

final class NativeOverlayScrollerView: NSView {
    private var retryScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyOverlayStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOverlayStyle()
    }

    func applyOverlayStyle() {
        if let scroll = enclosingScrollView {
            NativeOverlayScrollerOwner.attach(to: scroll)
        } else if superview != nil {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            retryScheduled = false
            // One attachment retry only; never poll a detached content view.
            if let scroll = enclosingScrollView {
                NativeOverlayScrollerOwner.attach(to: scroll)
            }
        }
    }

}

/// The policy lives as long as the native container, even after its initial
/// SwiftUI row is virtualized. One observer serves all realized row markers.
private final class NativeOverlayScrollerOwner: NSObject {
    private static var associationKey: UInt8 = 0
    private weak var scroll: NSScrollView?

    static func attach(to scroll: NSScrollView) {
        let owner: NativeOverlayScrollerOwner
        if let existing = objc_getAssociatedObject(scroll, &associationKey) as? NativeOverlayScrollerOwner {
            owner = existing
        } else {
            owner = NativeOverlayScrollerOwner(scroll: scroll)
            objc_setAssociatedObject(scroll, &associationKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        owner.applyOverlayStyle()
    }

    private init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferredStyleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
    }

    private func applyOverlayStyle() {
        if let scroll, scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
    }

    @objc nonisolated private func preferredStyleChanged(_ notification: Notification) {
        // AppKit also updates each scroll view for this notification. Reapply
        // after its delivery, without carrying the notification across actors.
        DispatchQueue.main.async { [weak self] in self?.applyOverlayStyle() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif
