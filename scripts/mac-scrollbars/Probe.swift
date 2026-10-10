import AppKit
import SwiftUI

@main
struct Probe {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        check("chat content", ScrollView {
            LazyVStack { ForEach(0..<100) { Text("Message \($0)") } }
                .nativeOverlayScrollers()
        }.scrollIndicators(.automatic))
        check("native sidebar rows", List {
            ForEach(0..<100) { Text("Session \($0)").nativeOverlayScrollers() }
        }.listStyle(.sidebar))
        check("native grouped settings", Form {
            Section("Display") {
                Text("Display size").nativeOverlayScrollers()
                ForEach(0..<40) { Text("Setting \($0)") }
            }
        }.formStyle(.grouped))

        let unrelated = NSScrollView()
        unrelated.scrollerStyle = .legacy
        weak var released: NativeOverlayScrollerView?
        autoreleasepool {
            let root = NSView()
            let marker = NativeOverlayScrollerView()
            released = marker
            root.addSubview(marker)
            marker.removeFromSuperview()
        }
        pump()
        precondition(released == nil && unrelated.scrollerStyle == .legacy)
        print("PASS detached marker releases; unrelated scroll views keep their style")
    }

    @MainActor
    static func check<V: View>(_ label: String, _ content: V) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: content)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump()
        host.layoutSubtreeIfNeeded()
        // Read-only inspection of the mounted fixture; production resolves
        // only the public enclosingScrollView and never scans descendants.
        let markers = descendants(host).compactMap { $0 as? NativeOverlayScrollerView }
        let targets = markers.compactMap(\.enclosingScrollView)
        precondition(!targets.isEmpty, "\(label): content did not reach its native scroll view")
        let scroll = targets[0]
        precondition(targets.allSatisfy { $0 === scroll }, "\(label): ambiguous scroll ownership")
        precondition(scroll.scrollerStyle == .overlay && scroll.hasVerticalScroller)
        precondition(markers.allSatisfy { $0.hitTest(.zero) == nil && $0.frame.size == .zero })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.origin
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        pump()
        precondition(scroll.scrollerStyle == .overlay && scroll.hasVerticalScroller)
        precondition(abs(scroll.contentView.bounds.origin.y - offset.y) < 1)
        precondition(scroll.verticalScroller?.action != nil && scroll.verticalScroller?.target != nil)
        precondition(scroll.contentView.frame.width >= scroll.bounds.width - 1)
        print("PASS \(label): public ownership, native scroller, no reserved column, transparent zero-size marker, preference recovery and reading offset")

        let detached = markers.first
        window.contentView = NSView()
        // A detached tree must not respond to subsequent preference changes.
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        pump()
        precondition(scroll.scrollerStyle == .legacy)
        precondition(detached?.window == nil)
    }

    @MainActor
    static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
