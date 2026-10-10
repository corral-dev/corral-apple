import Foundation

/// Product-level gates for unfinished surfaces.
///
/// Keep implementation code in the tree; only hide user-visible entry points
/// until the feature is polished enough to ship.
enum ProductFeatures {
    /// Session-detail terminal pane (segmented control + swipe + screen watch).
    ///
    /// Off since 2026-09-10: tried on device, too many issues; polish chat /
    /// pairing / list / push first. Flip to `true` only when terminal is ready
    /// to expose again — do not leave half-finished UI reachable.
    static let terminalPaneEnabled = false
}
