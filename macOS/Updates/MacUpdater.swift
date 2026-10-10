#if CORRAL_DIRECT_DOWNLOAD
import Foundation
import Observation
import Sparkle

/// Direct-download builds only. Sparkle owns preferences and its native update UI.
@MainActor
@Observable
final class MacUpdater {
    static let shared = MacUpdater()

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    private(set) var automaticallyDownloadsUpdates = true
    private(set) var allowsAutomaticUpdates = true

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private init() {
        // Same standard controller used by the existing MacKit/JotBox integration.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        for keyPath in [\SPUUpdater.canCheckForUpdates,
                        \SPUUpdater.automaticallyChecksForUpdates,
                        \SPUUpdater.automaticallyDownloadsUpdates,
                        \SPUUpdater.allowsAutomaticUpdates] {
            observations.append(controller.updater.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    private func refresh() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }
}
#endif
