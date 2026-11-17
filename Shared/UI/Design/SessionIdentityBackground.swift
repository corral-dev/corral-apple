import SwiftUI

/// Viewport-anchored decoration. Always mount behind content, not as an overlay;
/// native text, selection and opaque message/ANSI surfaces keep their own ink.
struct SessionIdentityBackground: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String

    /// Owner request 2026-11-16: the balanced 0.10 (light) / 0.14 (dark) mark was
    /// too faint to recognize at a glance. A bright emoji fades into a white pane
    /// faster than into a dark one, so the light value is higher for the same
    /// seen weight. Increased contrast keeps the decoration below content ink at
    /// roughly half weight instead of removing it.
    private var markOpacity: Double {
        if contrast == .increased { return colorScheme == .dark ? 0.12 : 0.16 }
        return colorScheme == .dark ? 0.22 : 0.30
    }

    var body: some View {
        GeometryReader { geometry in
            if let icon = SessionPresentation.titleIcon(in: title) {
                let inset = Space.base * interfaceScale
                let side = max(0, min(240 * interfaceScale,
                                      (geometry.size.width - 2 * inset) * 0.40,
                                      (geometry.size.height - 2 * inset) * 0.40))
                Text(verbatim: icon)
                    .font(.system(size: max(1, side * 0.82)))
                    .lineLimit(1)
                    .frame(width: side, height: side)
                    .opacity(markOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(inset)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
