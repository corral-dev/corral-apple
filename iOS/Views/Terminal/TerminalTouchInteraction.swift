import SwiftTerm
import UIKit

/// Touch policy shared by the iPhone's agent and project terminals. Keep
/// UIScrollView's native history scrolling; mouse-enabled TUIs receive wheels.
@MainActor
final class TerminalTouchInteraction: NSObject, UIGestureRecognizerDelegate {
    private weak var terminal: ShellTerminalHost?
    private let wheelPan = UIPanGestureRecognizer()
    private var remainingTranslation: CGFloat = 0
    private var previousTranslation: CGFloat = 0
    private var wheelPoint = CGPoint.zero
    private var momentum: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var momentumStarted: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0

    init(terminal: ShellTerminalHost) {
        self.terminal = terminal
        super.init()
        wheelPan.maximumNumberOfTouches = 1
        wheelPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        wheelPan.addTarget(self, action: #selector(scroll(_:)))
        wheelPan.delegate = self
        terminal.addGestureRecognizer(wheelPan)
        // Do not replace UIScrollView's delegate or its inertia. This gesture
        // fails immediately for local history or an existing selection.
        terminal.panGestureRecognizer.require(toFail: wheelPan)
        terminal.panGestureRecognizer.addTarget(self, action: #selector(cancelMomentumOnTouch(_:)))
        for gesture in terminal.gestureRecognizers ?? [] {
            if let longPress = gesture as? UILongPressGestureRecognizer {
                longPress.addTarget(self, action: #selector(selectText(_:)))
            } else if let tap = gesture as? UITapGestureRecognizer {
                tap.addTarget(self, action: #selector(cancelMomentumOnTouch(_:)))
            }
        }
    }

    func reset() {
        cancelScrolling()
        terminal?.selection?.selectNone()
    }

    func cancelScrolling() {
        momentum?.invalidate()
        momentum = nil
        momentumVelocity = 0
        remainingTranslation = 0
        previousTranslation = 0
    }

    private var forwardsWheel: Bool {
        guard let terminal else { return false }
        return terminal.canSendTouchInput && !terminal.hasActiveSelection
            && terminal.getTerminal().mouseMode != .off
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === wheelPan, forwardsWheel, let terminal else { return false }
        let velocity = wheelPan.velocity(in: terminal)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        cancelScrolling()
        return true
    }

    @objc private func cancelMomentumOnTouch(_ gesture: UIGestureRecognizer) {
        cancelScrolling()
    }

    @objc private func selectText(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        cancelScrolling()
        // SwiftTerm's original target records the native hit and shows its
        // standard menu. Run after all targets, then use its Select action to
        // start a word selection directly, retaining its handles/edge scroll.
        DispatchQueue.main.async { [weak self] in
            guard let terminal = self?.terminal, !terminal.isHidden else { return }
            terminal.select(nil)
        }
    }

    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        guard let terminal else { return }
        switch gesture.state {
        case .began:
            cancelScrolling()
            wheelPoint = gesture.location(in: terminal)
            consume(gesture.translation(in: terminal).y)
            previousTranslation = gesture.translation(in: terminal).y
        case .changed:
            guard forwardsWheel else { cancelScrolling(); return }
            let translation = gesture.translation(in: terminal).y
            wheelPoint = gesture.location(in: terminal)
            consume(translation - previousTranslation)
            previousTranslation = translation
        case .ended:
            guard forwardsWheel else { cancelScrolling(); return }
            let translation = gesture.translation(in: terminal).y
            consume(translation - previousTranslation)
            startMomentum(velocity: gesture.velocity(in: terminal).y)
        case .cancelled, .failed:
            cancelScrolling()
        default:
            break
        }
    }

    private func consume(_ delta: CGFloat) {
        guard forwardsWheel, let terminal else { return }
        let rows = max(1, terminal.getTerminal().rows)
        let cellHeight = terminal.getOptimalFrameSize().height / CGFloat(rows)
        guard cellHeight > 0 else { return }
        remainingTranslation += delta
        let lines = Int(remainingTranslation / cellHeight)
        guard lines != 0 else { return }
        remainingTranslation -= CGFloat(lines) * cellHeight
        terminal.sendTouchScroll(lines: lines, at: wheelPoint)
    }

    private func startMomentum(velocity: CGFloat) {
        guard abs(velocity) > 30, forwardsWheel else { cancelScrolling(); return }
        momentumVelocity = velocity
        momentumStarted = CACurrentMediaTime()
        lastFrame = momentumStarted
        let link = CADisplayLink(target: self, selector: #selector(coast(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        momentum = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func coast(_ link: CADisplayLink) {
        guard forwardsWheel, let terminal, !terminal.isHidden, terminal.window != nil,
              link.timestamp - momentumStarted < 2, abs(momentumVelocity) > 10 else {
            cancelScrolling()
            return
        }
        let elapsed = max(0, min(link.timestamp - lastFrame, 1.0 / 15))
        lastFrame = link.timestamp
        consume(momentumVelocity * elapsed)
        momentumVelocity *= pow(terminal.decelerationRate.rawValue, elapsed * 1_000)
    }
}
