import SwiftUI

#if os(macOS)
import AppKit
#endif

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
        NotificationCenter.default.removeObserver(self)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferredStyleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
        applyOverlayStyle()
    }

    func applyOverlayStyle() {
        if let scroll = enclosingScrollView {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
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
            if let scroll = enclosingScrollView, scroll.scrollerStyle != .overlay {
                scroll.scrollerStyle = .overlay
            }
        }
    }

    @objc nonisolated private func preferredStyleChanged(_ notification: Notification) {
        // AppKit also updates each scroll view for this notification. Reapply
        // after its delivery, without carrying the notification across actors.
        DispatchQueue.main.async { [weak self] in self?.applyOverlayStyle() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif
