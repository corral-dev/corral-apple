import QuartzCore
import SwiftUI
import UIKit

/// Fixed-size working cue: Core Animation owns interpolation, not the view graph.
///
/// iPhone counterpart of `MacWorkingDots`. SwiftUI interpolates animations in the app
/// process every frame, so the eased TimelineView beat re-rendered the conversation at
/// display rate (up to 120 Hz) whenever a session showed Working. Layer keyframes run in
/// the render server; SwiftUI still positions this fixed-size view next to the label.
struct IOSWorkingDots: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> DotsView { DotsView() }
    func updateUIView(_ view: DotsView, context: Context) { view.configure(color.cgColor) }

    final class DotsView: UIView {
        private var currentColor: CGColor?
        private var dots: [CALayer] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }

        func configure(_ color: CGColor) {
            guard currentColor != color else { return }
            currentColor = color
            if dots.isEmpty {
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
            dots.forEach { $0.backgroundColor = color }
            CATransaction.commit()
            animateIfVisible()
        }

        // Backgrounding or leaving the window can drop layer animations; re-add on return.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { dots.forEach { $0.removeAllAnimations() } }
            else { animateIfVisible() }
        }

        private func animateIfVisible() {
            guard window != nil else { return }
            for (index, dot) in dots.enumerated() where dot.animation(forKey: "working") == nil {
                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [0.35, 1, 0.35, 0.35]
                // UIKit layers are y-down: a negative offset lifts the dot.
                let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
                lift.values = [0, -2, 0, 0]
                for animation in [opacity, lift] {
                    animation.keyTimes = [0, 1.0 / 3, 2.0 / 3, 1] as [NSNumber]
                    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                }
                let group = CAAnimationGroup()
                group.animations = [opacity, lift]
                group.duration = 1.2
                group.repeatCount = .infinity
                group.isRemovedOnCompletion = false
                group.timeOffset = (1.2 - Double(index) * 0.4).truncatingRemainder(dividingBy: 1.2)
                dot.add(group, forKey: "working")
            }
        }
    }
}
