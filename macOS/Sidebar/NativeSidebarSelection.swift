import AppKit
import SwiftUI

/// Requests AppKit's neutral row selection while retaining native keyboard focus.
struct NativeSidebarSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionAppearanceView {
        SelectionAppearanceView()
    }

    func updateNSView(_ nsView: SelectionAppearanceView, context: Context) {
        nsView.bindRow()
    }

    static func dismantleNSView(_ nsView: SelectionAppearanceView, coordinator: ()) {
        nsView.unbindRow()
    }

    final class SelectionAppearanceView: NSView {
        private weak var row: NSTableRowView?
        private var observation: NSKeyValueObservation?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            bindRow()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bindRow()
        }

        func bindRow() {
            var ancestor = superview
            while let view = ancestor, !(view is NSTableRowView) {
                ancestor = view.superview
            }
            let enclosingRow = ancestor as? NSTableRowView
            guard row !== enclosingRow else { return }
            unbindRow()
            guard let enclosingRow else { return }
            row = enclosingRow
            observation = enclosingRow.observe(\.isEmphasized, options: [.new]) { row, _ in
                // AppKit's main-actor property changes synchronously on the UI thread.
                MainActor.assumeIsolated {
                    if row.isEmphasized { row.isEmphasized = false }
                }
            }
            enclosingRow.isEmphasized = false
        }

        func unbindRow() {
            observation?.invalidate()
            observation = nil
            row = nil
        }
    }
}
