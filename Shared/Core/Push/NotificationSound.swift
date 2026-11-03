import Foundation

/// Corral's own notification sound presets; notifications never use the system default.
///
/// iOS keeps the choice in the shared Keychain group because the notification
/// service extension cannot read the app's defaults; the Mac has no extension.
nonisolated enum NotificationSound: String, CaseIterable, Identifiable, Sendable {
    case woodenDuet = "wooden-duet"
    case waterDrop = "water-drop"
    case electronicChime = "electronic-chime"

    static let `default` = NotificationSound.electronicChime
    static let storageKey = "corral.notificationSound"

    var id: String { rawValue }

    /// Bundled CAF converted from the approved MP3 master by `scripts/notification-sounds/generate.py`.
    var fileName: String { "corral-\(rawValue).caf" }

    static func resolve(stored: String?) -> NotificationSound {
        // Resolve old choices here too: the notification extension reads the
        // Keychain before the user next opens Settings or launches the app.
        switch stored {
        case "chime": .electronicChime
        case "marimba": .woodenDuet
        case "tap": .waterDrop
        default: stored.flatMap(NotificationSound.init(rawValue:)) ?? .default
        }
    }

    static var selected: NotificationSound {
        #if os(iOS)
        resolve(stored: HostKeychain.readNotificationSound())
        #else
        resolve(stored: UserDefaults.standard.string(forKey: storageKey))
        #endif
    }

    static func select(_ sound: NotificationSound) {
        #if os(iOS)
        try? HostKeychain.saveNotificationSound(sound.rawValue)
        #else
        UserDefaults.standard.set(sound.rawValue, forKey: storageKey)
        #endif
    }
}
