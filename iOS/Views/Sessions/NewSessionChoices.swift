#if os(iOS)
import SwiftUI

/// The desktop dialog's native capsule treatment, with a touch-sized label.
/// Selection changes style without stretching the label into unused row space.
struct NewSessionChoiceButton<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var selected = false
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        Group {
            if selected { button.buttonStyle(.borderedProminent) }
            else { button.buttonStyle(.bordered) }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(selected ? Palette.accent : Color.secondary)
        .frame(minHeight: TouchTarget.minimum)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) { content() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? Palette.onAccent : Color.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
    }
}

/// Each native button keeps its ideal width; only a full row causes wrapping.
struct NewSessionChoiceFlow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        NewSessionWrappingLayout(spacing: Space.sm) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Uses native layout proposals, including a bounded proposal for a long label.
/// Measurement and placement share the same arrangement and child sizes.
private struct NewSessionWrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = idealSizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, subviews.count - 1)) * spacing
        let available = width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? naturalWidth
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (subview, ideal) in zip(subviews, idealSizes) {
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, available), height: nil))
            if x > 0 && x + size.width > available + 0.5 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: available, height: y + rowHeight), frames)
    }
}
#endif
