import SwiftUI

/// Single-row quick-filter layout that keeps spacing compact and fixed while
/// sizing all runtime buttons equally within `[minItemWidth, maxItemWidth]`:
/// scrolls smoothly below the minimum width, fills the viewport flush inside the
/// range, and caps cleanly at the maximum width on wide containers.
struct AdaptiveFilterRowLayout: Layout {
    let viewportWidth: CGFloat
    let dividerIndex: Int
    let dividerGap: CGFloat
    let itemGap: CGFloat
    let minItemWidth: CGFloat
    let maxItemWidth: CGFloat

    struct CacheData {
        var fixedSizes: [CGSize] = []
        var itemHeight: CGFloat = 0
        var buttonWidth: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout CacheData
    ) -> CGSize {
        let metrics = computeMetrics(subviews: subviews)
        cache = metrics.cache
        return CGSize(width: metrics.totalWidth, height: metrics.maxHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout CacheData
    ) {
        guard !subviews.isEmpty else { return }
        let buttonWidth = cache.buttonWidth > 0 ? cache.buttonWidth : computeMetrics(subviews: subviews).cache.buttonWidth
        let itemHeight = cache.itemHeight

        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let size: CGSize
            if isRuntimeItem(index) {
                size = CGSize(width: buttonWidth, height: itemHeight)
            } else {
                let fixed = index < cache.fixedSizes.count
                    ? cache.fixedSizes[index]
                    : subview.sizeThatFits(.unspecified)
                size = fixed
            }
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(size)
            )
            guard index < subviews.count - 1 else { break }
            x += size.width + (isDividerGap(index) ? dividerGap : itemGap)
        }
    }

    private func isRuntimeItem(_ index: Int) -> Bool {
        index > dividerIndex
    }

    private func isDividerGap(_ gapIndex: Int) -> Bool {
        gapIndex == dividerIndex - 1 || gapIndex == dividerIndex
    }

    private func computeMetrics(subviews: Subviews) -> (totalWidth: CGFloat, maxHeight: CGFloat, cache: CacheData) {
        let count = subviews.count
        var fixedSizes: [CGSize] = []
        var fixedWidthSum: CGFloat = 0
        var maxHeight: CGFloat = 0
        var maxRuntimeHeight: CGFloat = 0
        var runtimeCount = 0

        for (index, subview) in subviews.enumerated() {
            let measured = subview.sizeThatFits(.unspecified)
            maxHeight = max(maxHeight, measured.height)
            if isRuntimeItem(index) {
                runtimeCount += 1
                maxRuntimeHeight = max(maxRuntimeHeight, measured.height)
            } else {
                fixedSizes.append(measured)
                fixedWidthSum += measured.width
            }
        }

        let dividerGaps = count > 1
            ? (0..<(count - 1)).reduce(0) { $0 + (isDividerGap($1) ? 1 : 0) }
            : 0
        let itemGaps = max(0, count - 1 - dividerGaps)
        let gapsTotal = CGFloat(dividerGaps) * dividerGap + CGFloat(itemGaps) * itemGap

        let upperBound = max(minItemWidth, maxItemWidth)
        let effectiveViewport = viewportWidth > 0 ? viewportWidth : 0
        let availableForRuntimes = effectiveViewport - fixedWidthSum - gapsTotal
        let rawWidth = runtimeCount > 0 ? availableForRuntimes / CGFloat(runtimeCount) : 0
        let buttonWidth = min(upperBound, max(minItemWidth, rawWidth))
        let totalWidth = fixedWidthSum + gapsTotal + CGFloat(runtimeCount) * buttonWidth

        let cache = CacheData(
            fixedSizes: fixedSizes,
            itemHeight: maxRuntimeHeight,
            buttonWidth: buttonWidth
        )
        return (totalWidth, maxHeight, cache)
    }
}
