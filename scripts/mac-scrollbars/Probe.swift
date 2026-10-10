import AppKit
import SwiftUI
import Observation

@main
struct Probe {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        check("chat content", ScrollView {
            LazyVStack { ForEach(0..<100) { Text("Message \($0)") } }
                .nativeOverlayScrollers()
        }.scrollIndicators(.automatic))
        checkDeferredConfiguration()
        checkSidebarSelection()

        let unrelated = NSScrollView()
        unrelated.scrollerStyle = .legacy
        weak var released: NativeOverlayScrollerView?
        weak var releasedScroll: NSScrollView?
        autoreleasepool {
            let scroll = NSScrollView()
            releasedScroll = scroll
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
            scroll.documentView = root
            let marker = NativeOverlayScrollerView()
            released = marker
            root.addSubview(marker)
            marker.removeFromSuperview()
        }
        pump()
        precondition(released == nil && releasedScroll == nil && unrelated.scrollerStyle == .legacy)
        print("PASS configured container and marker release without a cycle; unrelated scroll views keep their style")
    }

    @MainActor
    static func checkDeferredConfiguration() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.scrollerStyle = .legacy
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        scroll.documentView = root
        let marker = NativeOverlayScrollerView()
        root.addSubview(marker)
        for _ in 0..<100 { marker.applyOverlayStyle() }
        precondition(scroll.scrollerStyle == .legacy, "Configuration changed geometry inside attachment/update")
        pump()
        precondition(scroll.scrollerStyle == .overlay)
        scroll.scrollerStyle = .legacy
        marker.applyOverlayStyle()
        marker.removeFromSuperview()
        pump()
        precondition(scroll.scrollerStyle == .overlay)

        let tableScroll = NSScrollView()
        tableScroll.scrollerStyle = .legacy
        let table = NSTableView()
        tableScroll.documentView = table
        let misplaced = NativeOverlayScrollerView()
        table.addSubview(misplaced)
        pump()
        precondition(tableScroll.scrollerStyle == .legacy, "Native table layout was overridden")
        print("PASS deferred geometry, repeated updates, detachment and native table exclusion")
    }

    @MainActor
    static func checkSidebarSelection() {
        let state = SidebarState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 550),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SidebarFixture(state: state))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump()
        guard let table = descendants(host).compactMap({ $0 as? NSOutlineView }).first else {
            preconditionFailure("Native sidebar outline was not mounted")
        }
        var selections = 0
        for cycle in 0..<3 {
            for row in 1..<min(table.numberOfRows, 20) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                host.layoutSubtreeIfNeeded()
                if state.selection != nil { selections += 1 }
                window.setContentSize(NSSize(width: 850 + cycle * 10, height: 550))
            }
        }
        precondition(selections >= 40, "Native selection did not reach the SwiftUI binding")
        let sidebarMarkers = descendants(table).compactMap { $0 as? NativeOverlayScrollerView }
        precondition(sidebarMarkers.isEmpty, "Sidebar still configures SwiftUI's scroll layout")
        print("PASS \(selections) native outline selections with detail replacement and resize")
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
        pump()
        host.layoutSubtreeIfNeeded()
        pump()
        let offset = scroll.contentView.bounds.origin
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        pump()
        precondition(scroll.scrollerStyle == .overlay && scroll.hasVerticalScroller)
        precondition(abs(scroll.contentView.bounds.origin.y - offset.y) < 1, "Reading offset changed: \(offset) -> \(scroll.contentView.bounds.origin)")
        precondition(scroll.verticalScroller?.action != nil && scroll.verticalScroller?.target != nil)
        precondition(scroll.contentView.frame.width >= scroll.bounds.width - 1)
        print("PASS \(label): public ownership, native scroller, no reserved column, transparent zero-size marker, preference recovery and reading offset")

        let detached = markers.first
        window.contentView = NSView()
        // The policy survives virtualization of the initial marker row.
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        pump()
        precondition(scroll.scrollerStyle == .overlay)
        precondition(detached?.window == nil)
    }

    @MainActor
    static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor @Observable
private final class SidebarState {
    var selection: Int?
}

private struct SidebarFixture: View {
    let state: SidebarState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.selection }, set: { state.selection = $0 })) {
                Section("Sessions") {
                    ForEach(0..<40) { index in
                        Text("Session \(index)")
                            .background(NativeSidebarSelection())
                            .tag(index)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ScrollView {
                LazyVStack {
                    ForEach(0..<80) { Text("Conversation \(state.selection ?? 0), message \($0)") }
                }
                .nativeOverlayScrollers()
            }
            .id(state.selection)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
