import Foundation
import SwiftTerm

@MainActor
extension SwiftTerm.TerminalView {
    /// Resync is shared with other viewers. Expanding retained history must
    /// not pull a reader of an unchanged grid back to the live edge.
    /// A changed host grid re-wraps every row, so no row matches the reader's.
    func preservingViewportDuringSnapshot(hostGridChanged: Bool = false, _ update: () -> Void) {
        let grid = terminalDimensions
        let distance = canScroll && scrollPosition < 1 ? viewportDistanceFromLive() : nil
        update()
        guard let distance else { return }
        if !hostGridChanged, let currentDistance = viewportDistanceFromLive(),
           terminalInputStateSnapshot()?.isAlternateBuffer == false, terminalDimensions == grid {
            // Copied rows use absolute coordinates; viewportRow is buffer-relative.
            // Together they recover the current history length without copying
            // the 10,000-row scrollback. All Corral feeds/scrolls own this actor.
            let historyRows = terminalStateSnapshot().viewportRow + currentDistance
            scrollTo(row: max(0, historyRows - distance))
        } else {
            // A re-wrapped grid has no matching row; the reset left the reader
            // at the first retained line, so return to live output instead.
            scroll(toPosition: 1)
        }
    }

    private func viewportDistanceFromLive() -> Int? {
        guard let snapshot = terminalContentSnapshot(region: .viewport) else { return nil }
        return max(0, snapshot.liveTopRow - snapshot.capturedRange.lowerBound)
    }

    /// Absolute row of the viewport's top line; it only decreases when history
    /// above the viewport is erased (ED 3 or a full reset).
    private var viewportTopRow: Int? {
        terminalContentSnapshot(region: .viewport)?.capturedRange.lowerBound
    }

    private var isAtLiveEdge: Bool { !canScroll || scrollPosition >= 1 }

    /// The versioned emulator preserves selections whose content did not change.
    /// Configure the 10,000-row history once at host initialization, not per feed.
    ///
    /// SwiftTerm 1.99.1 keeps a scrolled reader pinned when ED 3 erases the
    /// history, so a full redraw (Pi sends `ESC[2J ESC[H ESC[3J` and the whole
    /// transcript on every resize) left the view on the conversation's first
    /// line. Host output that erases the reader's history returns to live
    /// output, as Ghostty does, and never moves a live viewer off the edge.
    func feedPreservingSelection(_ data: Data) {
        let wasLive = isAtLiveEdge
        let readerTop = wasLive ? nil : viewportTopRow
        data.withUnsafeBytes { raw in
            feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self)))
        }
        if wasLive {
            if !isAtLiveEdge { scroll(toPosition: 1) }
        } else if let readerTop, let top = viewportTopRow, top < readerTop {
            scroll(toPosition: 1)
        }
    }
}
