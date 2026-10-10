import SwiftUI

/// 会话列表与活动卡左侧的助手标识：官方图形优先，未知助手才回退系统符号。
struct RuntimeBadge: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let runtimeID: String?
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sm * interfaceScale, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .interfaceFrame(width: size, height: size)
            .overlay {
                if let name = Palette.runtimeLogoName(runtimeID) {
                    Image(name)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .interfacePadding(size * 0.16)
                } else {
                    Image(systemName: Palette.runtimeSymbol(runtimeID))
                        .interfaceFont(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.runtime(runtimeID))
                }
            }
            .accessibilityHidden(true)
    }
}
