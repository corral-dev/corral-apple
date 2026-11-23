import SwiftUI

extension TerminalRGB {
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

#if os(iOS)
/// Hides competing navigation-bar material and sets bar contrast when a terminal
/// surface supplies the full-bleed backdrop behind the navigation bar.
struct TerminalNavigationBarChrome: ViewModifier {
    let isActive: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 18.0, *) {
                content
                    .toolbarBackgroundVisibility(isActive ? .hidden : .automatic, for: .navigationBar)
            } else {
                content
                    .toolbarBackground(isActive ? .hidden : .automatic, for: .navigationBar)
            }
        }
        .toolbarColorScheme(isActive ? colorScheme : nil, for: .navigationBar)
    }
}

/// Suppresses system scroll-edge darkening/blur so the terminal canvas blends
/// seamlessly into top and bottom safe areas on iOS 26+.
struct TerminalScrollEdgeChrome: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(hidden, for: [.top, .bottom])
        } else {
            content
        }
    }
}
#endif
