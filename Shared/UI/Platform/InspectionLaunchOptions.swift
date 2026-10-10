import SwiftUI

#if DEBUG
/// Debug-only screen inspection switches, so acceptance never needs a second
/// test-runner app on the home screen.
enum InspectionLaunchOptions {
    private static var deliveryInspectionClaimed = false

    static func claimDeliveryInspection() -> Bool {
        guard !deliveryInspectionClaimed else { return false }
        deliveryInspectionClaimed = true
        return true
    }

    private static var rejectionClaimed = false

    static func claimRejectedSend(sessionKey: String, text: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard !rejectionClaimed,
              ProcessInfo.processInfo.arguments.contains("-CorralInspectDelivery"),
              env["CORRAL_INSPECTION_ACTION"] == "rejectRetry",
              env["CORRAL_INSPECTION_SESSION_KEY"] == sessionKey,
              text.contains("PHONE_RETRY_OK") else { return false }
        rejectionClaimed = true
        return true
    }

    static var forcedColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-CorralInspectLight") { return .light }
        if arguments.contains("-CorralInspectDark") { return .dark }
        return nil
    }
}
#endif
