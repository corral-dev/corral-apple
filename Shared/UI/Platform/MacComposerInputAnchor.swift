#if os(macOS)
import AppKit
import SwiftUI

/// Marks the existing SwiftUI TextField's public native bounds. It does not
/// replace the field or inspect private SwiftUI view classes.
struct MacComposerInputAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}

    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    static func field(in root: NSView) -> NSTextField? {
        let views = descendants(root)
        guard let marker = views.compactMap({ $0 as? Marker }).first,
              marker.window === root.window else { return nil }
        let bounds = marker.convert(marker.bounds, to: nil)
        guard !bounds.isEmpty else { return nil }
        return views.compactMap { $0 as? NSTextField }.first {
            $0.isEditable && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor
                && $0.convert($0.bounds, to: nil).intersects(bounds)
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }
}
#endif
