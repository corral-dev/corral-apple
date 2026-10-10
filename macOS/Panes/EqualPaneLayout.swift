import SwiftUI

/// Pane content shares the available width; each slot after the first also
/// carries its leading hairline. Known geometry avoids measuring conversations
/// at minimum/maximum widths just to establish their horizontal flexibility.
struct EqualPaneLayout: Layout {
    var minimumWidth: CGFloat
    var separatorWidth: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let minimum = CGFloat(subviews.count) * minimumWidth + CGFloat(subviews.count - 1) * separatorWidth
        let width = proposal.width.flatMap { $0.isFinite ? max($0, minimum) : nil } ?? minimum
        if let height = proposal.height, height.isFinite {
            return CGSize(width: width, height: max(height, 0))
        }
        let paneWidth = (width - CGFloat(subviews.count - 1) * separatorWidth) / CGFloat(subviews.count)
        let height = subviews.enumerated().reduce(CGFloat.zero) { height, item in
            let slotWidth = paneWidth + (item.offset > 0 ? separatorWidth : 0)
            return max(height, item.element.sizeThatFits(ProposedViewSize(width: slotWidth, height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let paneWidth = max(0, (bounds.width - CGFloat(subviews.count - 1) * separatorWidth) / CGFloat(subviews.count))
        var x = bounds.minX
        for (index, pane) in subviews.enumerated() {
            let slotWidth = paneWidth + (index > 0 ? separatorWidth : 0)
            pane.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: slotWidth, height: bounds.height))
            x += slotWidth
        }
    }
}
