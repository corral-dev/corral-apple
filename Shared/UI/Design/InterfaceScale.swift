import SwiftUI

private struct InterfaceScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Mac presentation scale. iOS never inherits the desktop preference.
    var interfaceScale: CGFloat {
        get {
            #if os(macOS)
            self[InterfaceScaleKey.self]
            #else
            1
            #endif
        }
        set { self[InterfaceScaleKey.self] = newValue }
    }
}

extension View {
    func interfaceFont(_ font: Font) -> some View {
        modifier(InterfaceFont(font: font))
    }

    func interfacePadding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        modifier(InterfacePadding(edges: edges, length: length))
    }

    func interfacePadding(_ length: CGFloat) -> some View {
        interfacePadding(.all, length)
    }

    /// Use only for design dimensions; measured viewport sizes stay in points.
    func interfaceFrame(width: CGFloat? = nil, height: CGFloat? = nil,
                        alignment: Alignment = .center) -> some View {
        modifier(InterfaceFixedFrame(width: width, height: height, alignment: alignment))
    }

    func interfaceFrame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                        minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                        alignment: Alignment = .center) -> some View {
        modifier(InterfaceFlexibleFrame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                                       minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight,
                                       alignment: alignment))
    }

    func interfaceControlSize(_ size: ControlSize) -> some View {
        modifier(InterfaceControlSize(size: size))
    }
}

private struct InterfaceFont: ViewModifier {
    @Environment(\.interfaceScale) private var scale
    let font: Font
    func body(content: Content) -> some View {
        #if os(macOS)
        content.font(font.scaled(by: scale))
        #else
        content.font(font)
        #endif
    }
}

private struct InterfacePadding: ViewModifier {
    @Environment(\.interfaceScale) private var scale
    let edges: Edge.Set
    let length: CGFloat?
    func body(content: Content) -> some View {
        content.padding(edges, length.map { $0 * scale })
    }
}

private struct InterfaceFixedFrame: ViewModifier {
    @Environment(\.interfaceScale) private var scale
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment
    func body(content: Content) -> some View {
        content.frame(width: width.map { $0 * scale }, height: height.map { $0 * scale }, alignment: alignment)
    }
}

private struct InterfaceFlexibleFrame: ViewModifier {
    @Environment(\.interfaceScale) private var scale
    let minWidth: CGFloat?
    let idealWidth: CGFloat?
    let maxWidth: CGFloat?
    let minHeight: CGFloat?
    let idealHeight: CGFloat?
    let maxHeight: CGFloat?
    let alignment: Alignment
    func body(content: Content) -> some View {
        content.frame(minWidth: value(minWidth), idealWidth: value(idealWidth), maxWidth: value(maxWidth),
                      minHeight: value(minHeight), idealHeight: value(idealHeight), maxHeight: value(maxHeight),
                      alignment: alignment)
    }
    private func value(_ dimension: CGFloat?) -> CGFloat? { dimension.map { $0 * scale } }
}

private struct InterfaceControlSize: ViewModifier {
    @Environment(\.interfaceScale) private var scale
    let size: ControlSize
    func body(content: Content) -> some View {
        #if os(macOS)
        content.controlSize(adapted)
        #else
        content.controlSize(size)
        #endif
    }
    #if os(macOS)
    private var adapted: ControlSize {
        if scale >= 1.25 {
            switch size {
            case .mini: return .small
            case .small: return .regular
            case .regular: return .large
            default: return size
            }
        }
        if scale < 0.95, size == .regular { return .small }
        return size
    }
    #endif
}
