import SwiftUI

struct StatusBarView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    private let title: Text
    var tint: Color = Palette.accent

    init(_ key: LocalizedStringKey, tint: Color = Palette.accent) {
        self.title = Text(key)
        self.tint = tint
    }

    init(verbatim text: String, tint: Color = Palette.accent) {
        self.title = Text(verbatim: text)
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: Space.sm * interfaceScale) {
            ProgressView()
                .interfaceControlSize(.small)
                .tint(tint)
            title
                .interfaceFont(Typography.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .interfacePadding(.horizontal, Space.base)
        .interfacePadding(.vertical, Space.sm)
        .background(.bar)
    }
}
