import AppKit
import SwiftUI

/// Requests AppKit's neutral row selection while retaining native keyboard focus.
struct NativeSidebarSelection: NSViewRepresentable {
    var revealSerial: Int? = nil
    var onReveal: () -> Void = {}
    /// nil means this marker no longer belongs to the current list structure.
    var selectedState: (() -> Bool?)? = nil

    /// Native repairs must not be interpreted as user navigation or batch edits.
    static var isReconcilingSelection = false

    /// Set only by the debug acceptance harness; unavailable in release UI.
    var debugKey: String? = nil

    func makeNSView(context: Context) -> SelectionAppearanceView {
        SelectionAppearanceView()
    }

    func updateNSView(_ nsView: SelectionAppearanceView, context: Context) {
        nsView.setRevealSerial(revealSerial)
        nsView.onReveal = onReveal
        nsView.selectedState = selectedState
        #if DEBUG
        nsView.debugKey = debugKey
        #endif
        nsView.bindRow()
        nsView.revealIfNeeded()
        nsView.reconcileSelection()
    }

    static func dismantleNSView(_ nsView: SelectionAppearanceView, coordinator: ()) {
        nsView.unbindRow()
        nsView.selectedState = nil
    }

    final class SelectionAppearanceView: NSView {
        private weak var row: NSTableRowView?
        private var observation: NSKeyValueObservation?
        var revealSerial: Int?
        var onReveal: () -> Void = {}
        private var completedReveal: Int?
        private weak var selectionTable: NSTableView?
        private var selectionRepairPending = false
        var selectedState: (() -> Bool?)?
        #if DEBUG
        var debugKey: String?
        #endif

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            bindRow()
            revealIfNeeded()
            reconcileSelection()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bindRow()
            revealIfNeeded()
            reconcileSelection()
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
            NotificationCenter.default.removeObserver(self)
            selectionTable = nil
            observation?.invalidate()
            observation = nil
            row = nil
        }

        @objc private func nativeSelectionChanged(_ notification: Notification) {
            reconcileSelection()
        }

        /// SwiftUI can preserve a Set binding while its mounted outline loses
        /// selection. Reconcile after its transaction, reading live model state
        /// rather than the value captured before a native selection gesture.
        func reconcileSelection() {
            guard selectedState != nil, !selectionRepairPending else { return }
            selectionRepairPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectionRepairPending = false
                guard self.window != nil, let row = self.row,
                      let table = self.enclosingScrollView?.documentView as? NSTableView,
                      let selected = self.selectedState?() else { return }
                if self.selectionTable !== table {
                    NotificationCenter.default.removeObserver(self)
                    self.selectionTable = table
                    let notification = table is NSOutlineView
                        ? NSOutlineView.selectionDidChangeNotification : NSTableView.selectionDidChangeNotification
                    NotificationCenter.default.addObserver(self, selector: #selector(self.nativeSelectionChanged(_:)),
                                                           name: notification, object: table)
                }
                let index = table.row(for: row)
                guard index >= 0, table.selectedRowIndexes.contains(index) != selected else { return }
                NativeSidebarSelection.isReconcilingSelection = true
                defer { NativeSidebarSelection.isReconcilingSelection = false }
                if selected {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
                } else {
                    table.deselectRow(index)
                }
            }
        }

        func setRevealSerial(_ serial: Int?) {
            if serial == nil { completedReveal = nil }
            revealSerial = serial
        }

        func revealIfNeeded() {
            guard let serial = revealSerial, completedReveal != serial, window != nil,
                  let row, let table = enclosingScrollView?.documentView as? NSTableView else { return }
            DispatchQueue.main.async { [weak self, weak table, weak row] in
                guard let self, let table, let row, self.row === row,
                      self.revealSerial == serial, self.window != nil else { return }
                let index = table.row(for: row)
                guard index >= 0 else { return }
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index)
                self.completedReveal = serial
                self.onReveal()
            }
        }

        #if DEBUG
        /// Read-only probe for the acceptance harness: the row this marker is
        /// mounted in, whether it is selected and whether it intersects the
        /// native list's visible rect.
        func debugRowState() -> (row: Int, selected: Bool, visible: Bool)? {
            guard let row, let table = enclosingScrollView?.documentView as? NSTableView else { return nil }
            let index = table.row(for: row)
            guard index >= 0 else { return nil }
            return (index, table.selectedRowIndexes.contains(index),
                table.rect(ofRow: index).intersects(table.visibleRect))
        }
        #endif
    }
}
