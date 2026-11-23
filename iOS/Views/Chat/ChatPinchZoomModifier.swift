#if os(iOS)
import SwiftUI
import UIKit

/// Configuration passed from `SessionDetailView` to the enclosing `UIScrollView`
/// pinch installer inside `ChatScrollView`.
struct ChatPinchZoomConfig {
    var isEnabled: Bool
    var currentScale: Double
    var onLiveScaleChange: (Double?) -> Void
    var onCommitScale: (Double) -> Void
}

private struct ChatPinchZoomConfigKey: EnvironmentKey {
    static let defaultValue: ChatPinchZoomConfig? = nil
}

extension EnvironmentValues {
    var chatPinchZoomConfig: ChatPinchZoomConfig? {
        get { self[ChatPinchZoomConfigKey.self] }
        set { self[ChatPinchZoomConfigKey.self] = newValue }
    }
}

extension View {
    func chatPinchZoom(
        isEnabled: Bool,
        currentScale: Double,
        onLiveScaleChange: @escaping (Double?) -> Void,
        onCommitScale: @escaping (Double) -> Void
    ) -> some View {
        environment(\.chatPinchZoomConfig, ChatPinchZoomConfig(
            isEnabled: isEnabled,
            currentScale: currentScale,
            onLiveScaleChange: onLiveScaleChange,
            onCommitScale: onCommitScale
        ))
    }

    /// Installs a UIKit `UIPinchGestureRecognizer` on the enclosing `UIScrollView`
    /// so two-finger pinch works cleanly over `UITextView` message bubbles on all
    /// supported iOS versions (17+) without SwiftUI gesture representable loss.
    func installChatPinchZoom() -> some View {
        background {
            ChatScrollPinchInstaller()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ChatScrollPinchInstaller: UIViewRepresentable {
    @Environment(\.chatPinchZoomConfig) private var config

    func makeCoordinator() -> ChatPinchZoomCoordinator {
        ChatPinchZoomCoordinator(config: config)
    }

    func makeUIView(context: Context) -> ChatPinchAnchorView {
        let view = ChatPinchAnchorView()
        view.coordinator = context.coordinator
        view.attachIfNeeded()
        return view
    }

    func updateUIView(_ uiView: ChatPinchAnchorView, context: Context) {
        context.coordinator.update(config: config)
        uiView.coordinator = context.coordinator
        uiView.attachIfNeeded()
    }

    static func dismantleUIView(_ uiView: ChatPinchAnchorView, coordinator: ChatPinchZoomCoordinator) {
        uiView.detach()
    }
}

final class ChatPinchAnchorView: UIView {
    weak var coordinator: ChatPinchZoomCoordinator?
    private weak var attachedScrollView: UIScrollView?
    private var retryScheduled = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil {
            detach()
        } else {
            attachIfNeeded()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            attachIfNeeded()
        }
    }

    func attachIfNeeded() {
        if let scroll = enclosingScrollView {
            guard attachedScrollView !== scroll else { return }
            detach()
            attachedScrollView = scroll
            coordinator?.attach(to: scroll)
        } else if superview != nil {
            scheduleRetry()
        }
    }

    func detach() {
        retryScheduled = false
        if let scroll = attachedScrollView {
            coordinator?.detach(from: scroll)
            attachedScrollView = nil
        }
    }

    private var enclosingScrollView: UIScrollView? {
        var cursor = superview
        while let view = cursor {
            if let scroll = view as? UIScrollView {
                return scroll
            }
            cursor = view.superview
        }
        return nil
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            retryScheduled = false
            guard attachedScrollView == nil, let scroll = enclosingScrollView else { return }
            attachedScrollView = scroll
            coordinator?.attach(to: scroll)
        }
    }
}

@MainActor
final class ChatPinchZoomCoordinator: NSObject, UIGestureRecognizerDelegate {
    var isEnabled: Bool
    var currentScale: Double
    var onLiveScaleChange: (Double?) -> Void
    var onCommitScale: (Double) -> Void

    let recognizer = UIPinchGestureRecognizer()
    private var startScale: Double?
    private var appliedLiveScale: Double?

    init(config: ChatPinchZoomConfig?) {
        self.isEnabled = config?.isEnabled ?? false
        self.currentScale = config?.currentScale ?? MobileZoomPreferences.chatDefaultScale
        self.onLiveScaleChange = config?.onLiveScaleChange ?? { _ in }
        self.onCommitScale = config?.onCommitScale ?? { _ in }
        super.init()
        recognizer.cancelsTouchesInView = true
        recognizer.isEnabled = self.isEnabled
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(handle(_:)))
    }

    func update(config: ChatPinchZoomConfig?) {
        let nextEnabled = config?.isEnabled ?? false
        isEnabled = nextEnabled
        currentScale = config?.currentScale ?? MobileZoomPreferences.chatDefaultScale
        onLiveScaleChange = config?.onLiveScaleChange ?? { _ in }
        onCommitScale = config?.onCommitScale ?? { _ in }
        recognizer.isEnabled = nextEnabled
        if !nextEnabled {
            startScale = nil
            appliedLiveScale = nil
        }
    }

    func attach(to scrollView: UIScrollView) {
        if let previous = recognizer.view, previous !== scrollView {
            previous.removeGestureRecognizer(recognizer)
        }
        if recognizer.view !== scrollView {
            scrollView.addGestureRecognizer(recognizer)
        }
    }

    func detach(from scrollView: UIScrollView) {
        if recognizer.view === scrollView {
            scrollView.removeGestureRecognizer(recognizer)
        }
        startScale = nil
        appliedLiveScale = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Cooperate with vertical ScrollView and capped bubble inner pan gestures,
        // without interfering with long-press range selection or taps.
        otherGestureRecognizer is UIPanGestureRecognizer
    }

    @objc func handle(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard isEnabled else { return }
            if let scroll = recognizer.view as? UIScrollView {
                let pan = scroll.panGestureRecognizer
                if pan.state == .began || pan.state == .changed {
                    pan.isEnabled = false
                    pan.isEnabled = true
                }
            }
            startScale = currentScale
            appliedLiveScale = nil
        case .changed:
            guard isEnabled else { return }
            let base = startScale ?? currentScale
            if startScale == nil {
                startScale = base
            }
            let candidate = MobileZoomPreferences.scaledChatScale(
                from: base,
                magnification: Double(recognizer.scale)
            )
            if MobileZoomPreferences.shouldApplyLiveChatScale(
                candidate,
                current: appliedLiveScale ?? base
            ) {
                appliedLiveScale = candidate
                onLiveScaleChange(candidate)
            }
        case .ended:
            guard let base = startScale else { return }
            let final = MobileZoomPreferences.scaledChatScale(
                from: base,
                magnification: Double(recognizer.scale)
            )
            startScale = nil
            appliedLiveScale = nil
            onLiveScaleChange(nil)
            onCommitScale(final)
        case .cancelled, .failed:
            guard startScale != nil else { return }
            let committed = appliedLiveScale
            startScale = nil
            appliedLiveScale = nil
            onLiveScaleChange(nil)
            if let committed {
                onCommitScale(committed)
            }
        default:
            break
        }
    }
}
#endif
