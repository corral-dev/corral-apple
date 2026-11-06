import SwiftUI

/// Viewport-anchored decoration. Always mount behind content, not as an overlay;
/// native text, selection and opaque message/ANSI surfaces keep their own ink.
struct SessionIdentityBackground: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String

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
                    .opacity(contrast == .increased ? 0.035 : (colorScheme == .dark ? 0.10 : 0.07))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(inset)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
