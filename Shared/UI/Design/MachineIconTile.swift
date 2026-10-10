import SwiftUI

/// Paired-machine mark in the app-icon hat colors: pine tile, warm-yellow glyph.
struct MachineIconTile: View {
    @Environment(\.interfaceScale) private var interfaceScale
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27 * interfaceScale, style: .continuous)
            .fill(Palette.brandPine.gradient)
            .interfaceFrame(width: size, height: size)
            .overlay {
                Image(systemName: "desktopcomputer")
                    .interfaceFont(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Palette.brandYellow)
            }
            .accessibilityHidden(true)
    }
}
