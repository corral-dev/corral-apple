#if CORRAL_DIRECT_DOWNLOAD
import SwiftUI

struct MacUpdateCommands: Commands {
    @State private var updater = MacUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("mac.updates.check") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

struct MacUpdateSettings: View {
    @State private var updater = MacUpdater.shared

    var body: some View {
        Section("mac.updates.title") {
            Toggle("mac.updates.automatic_checks", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticChecks($0) }
            ))
            Toggle("mac.updates.automatic_downloads", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticDownloads($0) }
            ))
            .disabled(!updater.allowsAutomaticUpdates)
            Button("mac.updates.check") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
#endif
