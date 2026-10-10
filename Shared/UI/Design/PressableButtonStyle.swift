import SwiftUI

/// 自定义图标/圆形按钮的 touch-down 按下态（对齐交互指南团队 token）。
/// 系统 `.bordered` / `.borderedProminent` 已自带高亮，不要叠用本样式。
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var pressedScale: CGFloat = Motion.pressScale
    var pressedOpacity: Double = 0.72

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: Motion.pressDuration),
                value: configuration.isPressed
            )
    }
}

/// iOS 动效团队 token（交互指南起点；非 Apple 硬门槛）。
enum Motion {
    static let pressDuration: Double = 0.16
    static let pressScale: CGFloat = 0.97
    static let stateDuration: Double = 0.22
}
