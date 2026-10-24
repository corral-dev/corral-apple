import CoreGraphics

/// Window and sidebar fit rules for the Mac shell (owner decision 2026-10-24).
///
/// The window may shrink below the former fixed floor. Its minimum follows the
/// mounted panes; the sidebar steps aside when it would push them below their
/// own minimum, and returns once the window is wide enough again. These are
/// pure values so the sizing probe can exercise them without a window.
enum MacSidebarSizing {
    /// The narrowest useful conversation or terminal pane; the split owner
    /// keeps using this through `MacSplitArea.paneMinimum`.
    nonisolated static let paneMinimum: CGFloat = 220

    /// Floor for one or two panes once the sidebar has stepped aside.
    nonisolated static let baseWindowMinimum: CGFloat = 520

    /// Ideal sidebar width, used before the mounted sidebar reports itself or
    /// while it is collapsed.
    nonisolated static let fallbackSidebarWidth: CGFloat = 310

    /// Keeps the sidebar from sitting exactly against the pane minimum.
    nonisolated static let fitMargin: CGFloat = 40

    /// Widening this much past the collapse point brings the sidebar back.
    nonisolated static let expandHysteresis: CGFloat = 80

    /// Width taken by the panes at their minimum, including their dividers.
    nonisolated static func paneMinimumWidth(panes: Int) -> CGFloat {
        let count = CGFloat(max(panes, 1))
        return count * paneMinimum + max(count - 1, 0)
    }

    /// Narrowest window for the current panes once the sidebar is out of the way.
    nonisolated static func minimumWindowWidth(panes: Int) -> CGFloat {
        max(baseWindowMinimum, paneMinimumWidth(panes: panes))
    }

    /// Window width at which the sidebar stops fitting beside the panes.
    nonisolated static func collapseWidth(panes: Int, sidebarWidth: CGFloat) -> CGFloat {
        paneMinimumWidth(panes: panes) + max(sidebarWidth, 0) + fitMargin
    }

    nonisolated static func expandWidth(panes: Int, sidebarWidth: CGFloat) -> CGFloat {
        collapseWidth(panes: panes, sidebarWidth: sidebarWidth) + expandHysteresis
    }

    /// Sidebar automation while the window is being resized. A collapse needs
    /// a downward crossing; a manual show inside the narrow range is left
    /// alone until the window crosses again.
    nonisolated static func nextAutoCollapse(
        currentlyCollapsed: Bool,
        manuallyHidden: Bool,
        width: CGFloat,
        previousWidth: CGFloat?,
        collapseAt: CGFloat,
        expandAt: CGFloat
    ) -> Bool {
        if currentlyCollapsed {
            let wasNarrow = previousWidth.map { $0 < expandAt } ?? true
            return !(width >= expandAt && wasNarrow)
        }
        guard !manuallyHidden else { return false }
        let wasWide = previousWidth.map { $0 >= collapseAt } ?? true
        return width < collapseAt && wasWide
    }

    /// Pane-count or interface-scale changes move the thresholds without a
    /// width change; apply the fit rule directly, respecting a manual hide.
    nonisolated static func fitAfterLayoutChange(
        currentlyCollapsed: Bool,
        manuallyHidden: Bool,
        width: CGFloat,
        collapseAt: CGFloat,
        expandAt: CGFloat
    ) -> Bool {
        if currentlyCollapsed { return width < expandAt }
        guard !manuallyHidden else { return false }
        return width < collapseAt
    }
}
