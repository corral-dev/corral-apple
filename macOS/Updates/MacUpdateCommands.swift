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
    @State private var cliSync = MacCLISync.shared

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
            cliStatusRow
        }
        .task { await cliSync.refreshStatusIfIdle() }
    }

    @ViewBuilder
    private var cliStatusRow: some View {
        LabeledContent("mac.updates.cli_status") {
            HStack(spacing: 8) {
                switch cliSync.status {
                case .idle, .checking:
                    ProgressView().controlSize(.small)
                    Text("mac.updates.cli_checking")
                        .foregroundStyle(.secondary)
                case .synced(let version):
                    Text("mac.updates.cli_synced \(version)")
                        .foregroundStyle(.secondary)
                case .ahead(let cliVersion):
                    Text("mac.updates.cli_ahead \(cliVersion)")
                        .foregroundStyle(.secondary)
                case .devInstall(let version):
                    Text("mac.updates.cli_dev \(version)")
                        .foregroundStyle(.secondary)
                case .installing(let version):
                    ProgressView().controlSize(.small)
                    Text("mac.updates.cli_installing \(version)")
                        .foregroundStyle(.secondary)
                case .upgrading(_, let target):
                    ProgressView().controlSize(.small)
                    Text("mac.updates.cli_upgrading \(target)")
                        .foregroundStyle(.secondary)
                case .needsHomebrew:
                    Link("mac.pairing.get_homebrew", destination: MacLocalHostSetup.homebrewURL)
                case .failed:
                    Text("mac.updates.cli_needs_sync")
                        .foregroundStyle(.red)
                    Button("action.retry") { cliSync.syncNow() }
                }
            }
            .lineLimit(1)
        }
    }
}
#endif
