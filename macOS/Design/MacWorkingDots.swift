import AppKit
import QuartzCore
import SwiftUI

/// Fixed-size working cue: Core Animation owns interpolation, not the window graph.
struct MacWorkingDots: NSViewRepresentable {
    @Environment(\.interfaceScale) private var scale
    let color: NSColor

    func makeNSView(context: Context) -> DotsView { DotsView() }
    func updateNSView(_ view: DotsView, context: Context) { view.configure(color.cgColor, scale: scale) }

    final class DotsView: NSView {
        private var currentColor: CGColor?
        private var currentScale: CGFloat = 1
        private var dots: [CALayer] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(_ color: CGColor, scale: CGFloat) {
            guard currentColor != color || currentScale != scale else { return }
            currentScale = scale
            currentColor = color
            if dots.isEmpty, let layer {
                for index in 0..<3 {
                    let dot = CALayer()
                    dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
                    dot.position = CGPoint(x: 2.5 + CGFloat(index) * 9, y: 8)
                    dot.cornerRadius = 2.5
                    dot.opacity = 0.35
                    layer.addSublayer(dot)
                    dots.append(dot)
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, dot) in dots.enumerated() {
                dot.backgroundColor = color
                dot.bounds = CGRect(x: 0, y: 0, width: 5 * scale, height: 5 * scale)
                dot.position = CGPoint(x: (2.5 + CGFloat(index) * 9) * scale, y: 8 * scale)
                dot.cornerRadius = 2.5 * scale
            }
            CATransaction.commit()
            animateIfVisible()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { dots.forEach { $0.removeAllAnimations() } }
            else { animateIfVisible() }
        }

        private func animateIfVisible() {
            guard window != nil else { return }
            for (index, dot) in dots.enumerated() where dot.animation(forKey: "working") == nil {
                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [0.35, 1, 0.35, 0.35]
                let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
                lift.values = [0, layer?.contentsAreFlipped() == true ? -2 : 2, 0, 0]
                for animation in [opacity, lift] {
                    animation.keyTimes = [0, 1.0 / 3, 2.0 / 3, 1] as [NSNumber]
                    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                }
                let group = CAAnimationGroup()
                group.animations = [opacity, lift]
                group.duration = 1.2
                group.repeatCount = .infinity
                group.timeOffset = (1.2 - Double(index) * 0.4).truncatingRemainder(dividingBy: 1.2)
                dot.add(group, forKey: "working")
            }
        }
    }
}
