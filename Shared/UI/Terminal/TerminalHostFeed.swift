import Foundation
import SwiftTerm

@MainActor
extension SwiftTerm.TerminalView {
    /// Keep native selection through host redraws. SwiftTerm 1.20 clears it
    /// in feedPrepare and linefeed when this mouse-input gate is enabled.
    /// Parsing is synchronous; restore the gate before handling real input.
    func feedPreservingSelection(_ data: Data) {
        let mouseReporting = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = mouseReporting }
        data.withUnsafeBytes { raw in
            feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self)))
        }
    }
}
