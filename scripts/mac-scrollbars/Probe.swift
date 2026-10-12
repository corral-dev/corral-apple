import AppKit
import SwiftUI
import Observation

@main
struct Probe {
    @MainActor
    static func main() {
        // Same order as the app entry: the process preference precedes AppKit.
        let preferenceInstalled = CommandLine.arguments.contains("-CorralProbeScrollerPreference")
        if preferenceInstalled { MacScrollerPreference.install() }
        NSApplication.shared.setActivationPolicy(.prohibited)
        if preferenceInstalled {
            precondition(NSScroller.preferredScrollerStyle == .overlay, "Process scroller preference was not honored")
        }
        check("chat content", ScrollView {
            LazyVStack { ForEach(0..<100) { Text("Message \($0)") } }
                .nativeOverlayScrollers()
        }.scrollIndicators(.automatic))
        check("settings form", Form {
            ForEach(0..<100) { Text("Setting \($0)").nativeOverlayScrollers() }
        }.formStyle(.grouped))
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
        let tableMarker = NativeOverlayScrollerView()
        table.addSubview(tableMarker)
        tableMarker.applyOverlayStyle()
        pump()
        precondition(tableScroll.scrollerStyle == .legacy, "Native table scroller style was contested")
        print("PASS deferred geometry, repeated updates, detachment and native tables left to SwiftUI")
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
        guard let scroll = table.enclosingScrollView else { preconditionFailure("Missing sidebar scroll view") }
        precondition(scroll.scrollerStyle == NSScroller.preferredScrollerStyle, "Sidebar left the system scroller style")
        // Under the legacy preference SwiftUI reverts any override inside its
        // List update and retiles (the Mac 0.3.79 AttributeGraph abort).
        let changes = StyleChanges()
        changes.last = scroll.scrollerStyle
        // AppKit re-sets the same style on preference notices; count real flips.
        let observation = scroll.observe(\.scrollerStyle, options: []) { scroll, _ in
            MainActor.assumeIsolated {
                if scroll.scrollerStyle != changes.last { changes.count += 1 }
                changes.last = scroll.scrollerStyle
            }
        }
        defer { observation.invalidate() }
        var selections = 0
        for cycle in 0..<3 {
            for row in 1..<min(table.numberOfRows, 20) {
                NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                state.revision += 1
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                host.layoutSubtreeIfNeeded()
                if state.selection != nil { selections += 1 }
                window.setContentSize(NSSize(width: 850 + cycle * 10, height: 550))
            }
        }
        pump()
        precondition(selections >= 40, "Native selection did not reach the SwiftUI binding")
        precondition(changes.count == 0, "Sidebar scroller style changed \(changes.count) times during List updates")
        precondition(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
        if NSScroller.preferredScrollerStyle == .overlay {
            precondition(scroll.contentView.frame.width >= scroll.bounds.width - 1, "Sidebar reserves a scrollbar column")
        }
        print("PASS \(selections) native outline selections with row updates, preference notices and resize; List scroller style uncontested (preferred \(NSScroller.preferredScrollerStyle.rawValue))")
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
    var revision = 0
}

@MainActor
private final class StyleChanges {
    var count = 0
    var last = NSScroller.Style.overlay
}

private struct SidebarFixture: View {
    let state: SidebarState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.selection }, set: { state.selection = $0 })) {
                Section("Sessions") {
                    ForEach(0..<40) { index in
                        // The marker stays to prove List scrollers are left to SwiftUI.
                        Text("Session \(index) · \(state.revision)")
                            .background(NativeSidebarSelection())
                            .nativeOverlayScrollers()
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
