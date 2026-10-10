#if os(iOS)
import Foundation
import UIKit
import SwiftUI

@MainActor
final class HapticFeedback {
    static let shared = HapticFeedback()
    private var policy = HapticFeedbackPolicy()
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    private init() {}

    func emit(_ event: HapticEvent, operationID: UUID? = nil, scope: HapticScope? = nil) {
        let id = operationID ?? scope?.beginOperation() ?? UUID()
        guard policy.consume(
            event, operationID: id,
            isActive: UIApplication.shared.applicationState == .active,
            isVisible: scope?.allows(id) ?? true,
            now: ProcessInfo.processInfo.systemUptime
        ) else { return }
        switch event {
        case .selection: selection.selectionChanged()
        case .committed: impact.impactOccurred(intensity: 0.45)
        case .success: notification.notificationOccurred(.success)
        case .warning: notification.notificationOccurred(.warning)
        case .error: notification.notificationOccurred(.error)
        }
        #if DEBUG
        NSLog("Corral haptic: %@", event.rawValue)
        #endif
    }

    func failure(_ error: Error, operationID: UUID? = nil, scope: HapticScope? = nil) {
        guard let event = HapticEvent.failure(for: error) else { return }
        emit(event, operationID: operationID, scope: scope)
    }
}

extension View {
    func hapticScope(_ scope: HapticScope) -> some View {
        onAppear { scope.activate() }
            .onDisappear { scope.deactivate() }
    }
}
#else
import Foundation
import SwiftUI

/// macOS has no action/outcome haptics (Force Touch feedback is reserved for
/// drag alignment per the HIG), so the shared call sites are no-ops here.
@MainActor
final class HapticFeedback {
    static let shared = HapticFeedback()
    private init() {}

    func emit(_ event: HapticEvent, operationID: UUID? = nil, scope: HapticScope? = nil) {}
    func failure(_ error: Error, operationID: UUID? = nil, scope: HapticScope? = nil) {}
}

extension View {
    func hapticScope(_ scope: HapticScope) -> some View {
        onAppear { scope.activate() }
            .onDisappear { scope.deactivate() }
    }
}
#endif
