import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class LayoutProbeModel {
    var visible = ["a", "b"]
    var roster = ["a", "b"]
    @ObservationIgnored var views: [String: NSView] = [:]
    @ObservationIgnored var creations: [String: Int] = [:]
}
struct NativeSlotProbe: NSViewRepresentable {
    let key: String
    let model: LayoutProbeModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        model.views[key] = view
        model.creations[key, default: 0] += 1
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
struct RetainedLayoutProbeView: View {
    let model: LayoutProbeModel
    var body: some View {
        MacRetainedPaneLayout(visibleKeys: model.visible) {
            ForEach(model.roster, id: \.self) { key in
                NativeSlotProbe(key: key, model: model)
                    .opacity(model.visible.contains(key) ? 1 : 0)
                    .layoutValue(key: MacRetainedPaneKey.self, value: key)
            }
        }
    }
}
@MainActor enum MacSplitArea { nonisolated static let paneMinimum: CGFloat = 220 }
@MainActor func exerciseRetainedLayout() async {
    let model = LayoutProbeModel()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: RetainedLayoutProbeView(model: model))
    window.contentView = view
    window.orderFront(nil)
    for _ in 0..<4 { await Task.yield(); window.contentView?.layoutSubtreeIfNeeded() }
    try? await Task.sleep(for: .milliseconds(60))
    let a = model.views["a"]!
    let b = model.views["b"]!
    let sizes = [a.frame.size, b.frame.size]
    let frames = [a.convert(a.bounds, to: view), b.convert(b.bounds, to: view)]
    precondition(sizes[0].width > 0 && sizes[1].width > 0)
    for index in 0..<12 {
        model.visible = index.isMultiple(of: 2) ? ["c", "d"] : ["a", "b"]
        model.roster = model.visible + (index.isMultiple(of: 2) ? ["a", "b"] : ["c", "d"])
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
        precondition(a.frame.size == sizes[0] && b.frame.size == sizes[1],
                     "roster changes must not reflow hidden native slots")
        precondition(a.convert(a.bounds, to: view) == frames[0]
                     && b.convert(b.bounds, to: view) == frames[1],
                     "dormant native slots must stay at their previous position")
    }
    precondition(model.creations.values.allSatisfy { $0 == 1 },
                 "native slots must retain identity while dormant")
    model.visible = ["b", "a"]
    model.roster = ["a", "b", "c", "d"]
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(20))
    precondition(b.convert(b.bounds, to: view).minX < a.convert(a.bounds, to: view).minX,
                 "visible workspace order must be independent of retained roster order")
    window.orderOut(nil)
    print("PASS mounted layout: repeated split switching preserves native identity and dormant geometry")
}
