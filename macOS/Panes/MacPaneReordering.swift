import AppKit
import SwiftUI

/// Slot arithmetic of a live header drag (design: Pane header reordering).
/// The split shares its width equally, like `MacWorkspace.glide`.
nonisolated struct MacPaneDragGeometry {
    let width: CGFloat
    let count: Int

    var slotWidth: CGFloat { width / CGFloat(max(count, 1)) }

    func slotX(_ index: Int) -> CGFloat { slotWidth * CGFloat(index) }

    /// The pane travels with the pointer but never past the split's edges.
    func clampedTravel(_ travel: CGFloat, from origin: Int) -> CGFloat {
        min(max(travel, -slotX(origin)), slotX(count - 1) - slotX(origin))
    }

    /// The slot under the dragged pane's centre: a neighbour gives way once
    /// the pane covers half of it.
    func slot(origin: Int, travel: CGFloat) -> Int {
        guard count > 1, slotWidth > 0 else { return origin }
        let centre = slotX(origin) + clampedTravel(travel, from: origin) + slotWidth / 2
        return min(max(Int((centre / slotWidth).rounded(.down)), 0), count - 1)
    }
}

/// The header's leading strip (identity, status and blank space) moves its
/// pane; a press without travel still reaches the title button and the
/// header's focus tap. Trailing actions are not handles.
struct MacPaneReorderHandle: ViewModifier {
    @Environment(MacWorkspace.self) private var workspace
    let key: String
    @GestureState private var dragging = false
    @State private var anchor = MacWindowPointAnchor()
    @State private var startX: CGFloat?
    @State private var gestureID: UUID?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(MacWindowPointReader(anchor: anchor, key: key))
            .highPriorityGesture(drag, including: workspace.canReorderPanes ? .all : .subviews)
            .onChange(of: dragging) { _, active in
                guard !active, let endedGesture = gestureID else { return }
                // onEnded has already committed a finished drag; only a
                // gesture the system cancelled is still open here.
                Task { @MainActor in
                    guard gestureID == endedGesture else { return }
                    startX = nil
                    gestureID = nil
                    workspace.endPaneDrag(key, cancelled: true)
                }
            }
            .onDisappear {
                guard gestureID != nil else { return }
                startX = nil
                gestureID = nil
                workspace.endPaneDrag(key, cancelled: true)
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                // A live reorder moves the pane into another slot, so
                // gesture-local translation would jump with it. Window
                // coordinates stay on the pointer.
                guard let x = anchor.windowX(value.location.x) else { return }
                let start = startX ?? anchor.windowX(value.startLocation.x) ?? x
                if startX == nil {
                    gestureID = UUID()
                    workspace.beginPaneDrag(key)
                }
                #if DEBUG
                MacPaneReorderProbe.started = MacPaneReorderProbe.started + (startX == nil ? 1 : 0)
                MacPaneReorderProbe.changed += 1
                MacPaneReorderProbe.lastWindowX = x
                MacPaneReorderProbe.lastTravel = x - start
                #endif
                startX = start
                workspace.dragPane(key, travel: x - start)
            }
            .onEnded { _ in
                #if DEBUG
                MacPaneReorderProbe.ended += 1
                #endif
                startX = nil
                gestureID = nil
                workspace.endPaneDrag(key)
            }
    }
}

/// VoiceOver equivalent of the drag: one slot at a time.
struct MacPaneMoveActions: ViewModifier {
    @Environment(MacWorkspace.self) private var workspace
    let key: String

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text("mac.pane.move_left")) { workspace.movePane(key, by: -1) }
            .accessibilityAction(named: Text("mac.pane.move_right")) { workspace.movePane(key, by: 1) }
    }
}

/// Converts a point of the handle's local space to window coordinates, at
/// the frame the event was delivered in.
@MainActor
final class MacWindowPointAnchor {
    fileprivate weak var view: NSView?

    func windowX(_ localX: CGFloat) -> CGFloat? {
        guard let view, view.window != nil else { return nil }
        return view.convert(CGPoint(x: localX, y: 0), to: nil).x
    }
}

private struct MacWindowPointReader: NSViewRepresentable {
    let anchor: MacWindowPointAnchor
    let key: String

    final class ReaderView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        anchor.view = view
        #if DEBUG
        MacPaneReorderHandles.views[key] = view
        #endif
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        anchor.view = nsView
        #if DEBUG
        MacPaneReorderHandles.views[key] = nsView
        #endif
    }
}

#if DEBUG
/// Header handle strips by pane key, so acceptance presses the real handle.
@MainActor
enum MacPaneReorderHandles {
    static var views: [String: NSView] = [:]
}

/// What SwiftUI's header gesture actually received during acceptance.
@MainActor
enum MacPaneReorderProbe {
    static var started = 0
    static var changed = 0
    static var ended = 0
    static var lastWindowX: CGFloat?
    static var lastTravel: CGFloat?
    static func reset() {
        started = 0
        changed = 0
        ended = 0
        lastWindowX = nil
        lastTravel = nil
    }
}
#endif
