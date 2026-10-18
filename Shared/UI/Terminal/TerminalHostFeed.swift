import Foundation
import SwiftTerm

@MainActor
extension SwiftTerm.TerminalView {
    /// Resync is shared with other viewers. Expanding retained history must
    /// not pull a reader of an unchanged grid back to the live edge.
    func preservingViewportDuringSnapshot(_ update: () -> Void) {
        let emulator = getTerminal()
        let grid = (emulator.cols, emulator.rows)
        let distance = canScroll && scrollPosition < 1
            ? retainedHistoryRows() - emulator.getTopVisibleRow() : nil
        update()
        if let distance, !emulator.isCurrentBufferAlternate,
           emulator.cols == grid.0, emulator.rows == grid.1 {
            scrollTo(row: max(0, retainedHistoryRows() - distance))
        }
    }

    private func retainedHistoryRows() -> Int {
        let emulator = getTerminal(), trimmed = emulator.buffer.totalLinesTrimmed
        var lower = trimmed, upper = trimmed + max(1, emulator.rows)
        while emulator.getScrollInvariantLine(row: upper) != nil { upper = trimmed + (upper - trimmed) * 2 }
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if emulator.getScrollInvariantLine(row: middle) == nil { upper = middle }
            else { lower = middle + 1 }
        }
        return max(0, lower - trimmed - emulator.rows)
    }

    /// Keep native selection through host redraws. SwiftTerm 1.20 clears it
    /// in feedPrepare and linefeed when this mouse-input gate is enabled.
    /// Parsing is synchronous; restore the gate before handling real input.
    func feedPreservingSelection(_ data: Data) {
        // SwiftTerm defaults to 500 rows; host snapshots contain 1,500 and
        // an explicit prompt reveal can request the retained 10,000-row budget.
        if getTerminal().options.scrollback != 10_000 { changeScrollback(10_000) }
        let mouseReporting = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = mouseReporting }
        data.withUnsafeBytes { raw in
            feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self)))
        }
    }
}
