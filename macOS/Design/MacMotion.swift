import SwiftUI

/// Motion tokens of the Mac window (design: MACOS_CLIENT_DESIGN.md, Motion
/// design). Frequent actions stay instant; these animate only spatial or state
/// changes. Springs carry no bounce, so effect properties never overshoot.
/// Pane width is never interpolated (it refits terminals and reflows chat text
/// every frame). Under Reduce Motion, disclosures change instantly, entrances
/// keep only their fade, colour fades and crossfades stay.
enum MacMotion {
    /// A pane the user added fades in; a board page's panes also slide.
    static func paneEntrance(sliding: Bool, reduceMotion: Bool) -> Animation {
        (sliding && !reduceMotion ? Animation.smooth(duration: 0.26) : .easeOut(duration: 0.2)).inspected
    }

    /// Distance a board page's panes travel while they fade in.
    static let pageOffset: CGFloat = 24

    /// Split panes travelling to their new slots (offset only, never width).
    static let paneGlide: Animation = Animation.smooth(duration: 0.34).inspected

    /// A closed pane fading out in its slot before the others take the space.
    static let paneExitSeconds = 0.14
    static let paneExit: Animation = Animation.easeIn(duration: paneExitSeconds).inspected

    /// Focus marker and attention-dot colour.
    static let state: Animation = Animation.easeOut(duration: 0.15).inspected

    /// Chat ↔ terminal in one pane, and search result states.
    static let crossfade: Animation = Animation.easeInOut(duration: 0.18).inspected

    /// Prompts panel and inline tool steps opening or closing.
    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Animation.smooth(duration: 0.24).inspected
    }

    /// Debug-only slow motion for visual acceptance (`CORRAL_INSPECTION_MOTION_SLOWDOWN`,
    /// e.g. 10), so window captures can catch in-between frames. Always 1 in Release.
    static let inspectionSlowdown: Int = {
        #if DEBUG
        Int(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_MOTION_SLOWDOWN"] ?? "") ?? 1
        #else
        1
        #endif
    }()
}

extension MacMotion {
    /// Wall-clock time of a token for work that waits for it to finish.
    static func seconds(_ base: Double) -> Double { base * Double(inspectionSlowdown) }
}

private extension Animation {
    var inspected: Animation {
        MacMotion.inspectionSlowdown > 1 ? speed(1 / Double(MacMotion.inspectionSlowdown)) : self
    }
}
