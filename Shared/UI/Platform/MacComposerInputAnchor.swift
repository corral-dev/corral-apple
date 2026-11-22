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

    /// Finds the visible editable `NSTextView` inside the composer input container.
    static func textView(in root: NSView) -> NSTextView? {
        let views = descendants(root)
        guard let marker = views.compactMap({ $0 as? Marker }).first,
              marker.window === root.window else { return nil }
        let bounds = marker.convert(marker.bounds, to: nil)
        guard !bounds.isEmpty else { return nil }
        return views.compactMap { $0 as? NSTextView }.first {
            $0.isEditable && !$0.isHiddenOrHasHiddenAncestor
                && $0.convert($0.bounds, to: nil).intersects(bounds)
        }
    }

    /// Finds an editable fallback `NSTextField` inside the anchored composer when present.
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

    static func focusableInput(in root: NSView) -> NSView? {
        textView(in: root) ?? field(in: root)
    }

    static func currentText(in root: NSView) -> String? {
        if let textView = textView(in: root) { return textView.string }
        if let field = field(in: root) { return field.stringValue }
        return nil
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }
}
#endif
