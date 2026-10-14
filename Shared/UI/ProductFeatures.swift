import Foundation

/// Product-level entry gates. Mac panes own their separate terminal mode.
enum ProductFeatures {
    #if os(iOS)
    /// Native UIKit agent terminal approved 2026-10-14, replacing the Canvas mirror.
    static let terminalPaneEnabled = true
    #else
    static let terminalPaneEnabled = false
    #endif
}
