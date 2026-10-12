import Foundation

/// Corral's Mac surfaces use thin overlay scrollers even when the system
/// prefers legacy ones. SwiftUI List re-applies the preferred style inside its
/// own updates, and contesting it aborts AttributeGraph on macOS 26, so the
/// preference itself must resolve to overlay. The argument domain lives only
/// in this process; set it before AppKit first reads the style.
enum MacScrollerPreference {
    static func install() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
