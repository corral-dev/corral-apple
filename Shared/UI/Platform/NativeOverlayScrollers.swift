#if os(macOS)
import AppKit
#endif
import SwiftUI

extension View {
    /// Configure the enclosing native scroller after SwiftUI's current update.
    /// Attach inside ScrollView or Form content. List scrollers are left to
    /// SwiftUI, which reverts this style inside its own update; on the Mac the
    /// process scroller preference makes SwiftUI choose overlay itself.
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
    private var updateScheduled = false

    static func attach(to scroll: NSScrollView) {
        // SwiftUI's List coordinator re-applies the system scroller style
        // during its graph update and retiles synchronously; contesting it
        // reenters row hosting layout and aborts AttributeGraph.
        guard !(scroll.documentView is NSTableView) else { return }
        let owner: NativeOverlayScrollerOwner
        if let existing = objc_getAssociatedObject(scroll, &associationKey) as? NativeOverlayScrollerOwner {
            owner = existing
        } else {
            owner = NativeOverlayScrollerOwner(scroll: scroll)
            objc_setAssociatedObject(scroll, &associationKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        owner.scheduleOverlayStyle()
    }

    private init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferredStyleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
    }

    private func scheduleOverlayStyle() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            // Retiling during updateNSView or row attachment can reenter the
            // SwiftUI graph. Change geometry only after that update completes.
            guard let scroll else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        }
    }

    @objc nonisolated private func preferredStyleChanged(_ notification: Notification) {
        // AppKit also updates each scroll view for this notification. Reapply
        // after its delivery, without carrying the notification across actors.
        DispatchQueue.main.async { [weak self] in self?.scheduleOverlayStyle() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif
