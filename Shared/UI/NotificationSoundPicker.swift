import AudioToolbox
import SwiftUI

extension NotificationSound {
    var title: LocalizedStringKey {
        switch self {
        case .chime: "settings.notifications.sound.chime"
        case .marimba: "settings.notifications.sound.marimba"
        case .tap: "settings.notifications.sound.tap"
        }
    }
}

/// Native picker for the notification sound; every choice, including the
/// current one, plays a preview the way a real notification would sound.
struct NotificationSoundPicker: View {
    @State private var sound = NotificationSound.selected

    var body: some View {
        Picker("settings.notifications.sound", selection: Binding(
            get: { sound },
            set: { value in
                sound = value
                NotificationSound.select(value)
                NotificationSoundPreview.play(value)
            }
        )) {
            ForEach(NotificationSound.allCases) { sound in
                Text(sound.title).tag(sound)
            }
        }
    }
}

/// System sounds follow the ringer/silent switch and alert volume, matching
/// how the notification itself will sound.
@MainActor
private enum NotificationSoundPreview {
    private static var ids: [NotificationSound: SystemSoundID] = [:]

    static func play(_ sound: NotificationSound) {
        if let id = ids[sound] {
            AudioServicesPlaySystemSound(id)
            return
        }
        guard let url = Bundle.main.url(forResource: sound.fileName, withExtension: nil) else { return }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return }
        ids[sound] = id
        AudioServicesPlaySystemSound(id)
    }
}
