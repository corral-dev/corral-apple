import Foundation
import Observation

/// Keeps the companion `corral` CLI installed and synchronized with `Corral.app`'s
/// version on non-sandboxed macOS builds. Never touches `dev` editable installs or
/// downgrades a newer CLI.
@MainActor
@Observable
final class MacCLISync {
    static let shared = MacCLISync()

    enum Status: Equatable {
        case idle
        case checking
        case synced(version: String)
        case ahead(cliVersion: String)
        case devInstall(version: String)
        case installing(targetVersion: String)
        case upgrading(from: String, to: String)
        case needsHomebrew
        case failed(String)
    }

    struct Banner: Equatable {
        let isBusy: Bool
        let message: String
        let canCancel: Bool
    }

    private(set) var status: Status = .idle
    private(set) var banner: Banner?
    private(set) var lastSyncCompletionSerial = 0

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var bannerDismissTask: Task<Void, Never>?
    @ObservationIgnored private var launchTriggered = false
    @ObservationIgnored private var generation = 0

    private init() {}

    func syncOnLaunch() {
        guard !launchTriggered, !MacHostCommand.isSandboxed else { return }
        launchTriggered = true
        #if DEBUG
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        if args.contains("-CorralInspectUpdateSettings") {
            Task { await refreshStatus() }
            return
        }
        if args.contains(where: { $0.hasPrefix("-CorralInspect") }) ||
            env.keys.contains(where: { $0.hasPrefix("CORRAL_INSPECTION_") }) {
            return
        }
        #endif
        startSync(allowMutate: true)
    }

    func refreshStatusIfIdle() async {
        guard activeTask == nil, !MacHostCommand.isSandboxed else { return }
        await refreshStatus()
    }

    func refreshStatus() async {
        guard !MacHostCommand.isSandboxed else { return }
        await runSyncPass(allowMutate: false)
    }

    func syncNow() {
        guard !MacHostCommand.isSandboxed else { return }
        startSync(allowMutate: true)
    }

    func syncAfterSparkleCycle() {
        guard !MacHostCommand.isSandboxed else { return }
        startSync(allowMutate: true)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        generation &+= 1
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = nil
        Task { await refreshStatus() }
    }

    private func startSync(allowMutate: Bool) {
        activeTask?.cancel()
        generation &+= 1
        let current = generation
        activeTask = Task { [weak self] in
            await self?.runSyncPass(allowMutate: allowMutate, generation: current)
            guard let self, self.generation == current else { return }
            self.activeTask = nil
        }
    }

    private func runSyncPass(allowMutate: Bool, generation expectedGen: Int? = nil) async {
        func isCurrent() -> Bool {
            if Task.isCancelled { return false }
            if let expectedGen { return generation == expectedGen }
            return true
        }

        let appVersion = MacHostCommand.appMarketingVersion
        status = .checking
        let corralURL = await MacHostCommand.locateCorral()
        guard isCurrent() else { return }

        let inspected: (snapshot: CLIStatusSnapshot?, supportsVersionFlag: Bool)
        if let corralURL {
            inspected = await MacHostCommand.inspectCorral(corral: corralURL)
        } else {
            inspected = (nil, false)
        }
        guard isCurrent() else { return }

        let brewURL = MacHostCommand.locateHomebrew()
        let hasScriptPrereqs = inspected.snapshot == nil && brewURL == nil
            ? await MacHostCommand.hasScriptInstallPrerequisites()
            : false
        guard isCurrent() else { return }

        let action = CLIVersionSyncPolicy.decide(
            appVersion: appVersion,
            snapshot: inspected.snapshot,
            supportsVersionUpdateFlag: inspected.supportsVersionFlag,
            hasHomebrew: brewURL != nil,
            hasScriptPrerequisites: hasScriptPrereqs
        )

        switch action {
        case .upToDate:
            status = .synced(version: inspected.snapshot?.version ?? appVersion)
            if let corralURL {
                await MacHostCommand.restartLocalRemoteIfOutdated(corral: corralURL, targetVersion: appVersion)
            }
        case .ahead(let cliVersion):
            status = .ahead(cliVersion: cliVersion)
        case .devCheckout(let cliVersion):
            status = .devInstall(version: cliVersion)
        case .install(let targetVersion, let method):
            switch method {
            case .needsHomebrew:
                status = .needsHomebrew
                banner = nil
            case .brew, .script:
                guard allowMutate else {
                    status = .failed(String(localized: "mac.updates.cli_needs_sync"))
                    return
                }
                await performInstall(
                    targetVersion: targetVersion,
                    brewURL: method == .brew ? brewURL : nil,
                    isCurrent: isCurrent
                )
            }
        case .upgrade(let targetVersion, let channel, let viaVersionFlag):
            let currentVersion = inspected.snapshot?.version ?? "0.0.0"
            guard allowMutate, let corralURL else {
                status = .upgrading(from: currentVersion, to: targetVersion)
                return
            }
            await performUpgrade(
                corral: corralURL,
                from: currentVersion,
                to: targetVersion,
                channel: channel,
                viaVersionFlag: viaVersionFlag,
                isCurrent: isCurrent
            )
        }
    }

    private func performInstall(
        targetVersion: String,
        brewURL: URL?,
        isCurrent: () -> Bool
    ) async {
        status = .installing(targetVersion: targetVersion)
        showBanner(
            isBusy: true,
            message: String(localized: "mac.updates.cli_installing \(targetVersion)"),
            canCancel: true
        )
        do {
            if let brewURL {
                try await MacHostCommand.installCorral(brew: brewURL)
            } else {
                try await MacHostCommand.installCorralWithScript(version: targetVersion)
            }
            guard isCurrent() else { return }
            if let installed = await MacHostCommand.locateCorral() {
                await MacHostCommand.restartLocalRemoteIfOutdated(corral: installed, targetVersion: targetVersion)
                let post = await MacHostCommand.inspectCorral(corral: installed)
                guard isCurrent() else { return }
                let resolvedVersion = post.snapshot?.version ?? targetVersion
                status = .synced(version: resolvedVersion)
                lastSyncCompletionSerial &+= 1
                showCompletionBanner(String(localized: "mac.updates.cli_synced_toast \(resolvedVersion)"))
            } else {
                status = .failed(String(localized: "mac.pairing.corral_missing_after_install"))
                banner = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            status = .failed(error.localizedDescription)
            banner = nil
        }
    }

    private func performUpgrade(
        corral: URL,
        from: String,
        to targetVersion: String,
        channel: CLIChannel?,
        viaVersionFlag: Bool,
        isCurrent: () -> Bool
    ) async {
        status = .upgrading(from: from, to: targetVersion)
        showBanner(
            isBusy: true,
            message: String(localized: "mac.updates.cli_upgrading \(targetVersion)"),
            canCancel: true
        )
        do {
            try await MacHostCommand.upgradeCorral(
                corral: corral,
                targetVersion: targetVersion,
                channel: channel,
                viaVersionFlag: viaVersionFlag
            )
            guard isCurrent() else { return }
            await MacHostCommand.restartLocalRemoteIfOutdated(corral: corral, targetVersion: targetVersion)
            let post = await MacHostCommand.inspectCorral(corral: corral)
            guard isCurrent() else { return }
            let resolvedVersion = post.snapshot?.version ?? targetVersion
            status = .synced(version: resolvedVersion)
            lastSyncCompletionSerial &+= 1
            showCompletionBanner(String(localized: "mac.updates.cli_synced_toast \(resolvedVersion)"))
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            status = .failed(error.localizedDescription)
            banner = nil
        }
    }

    private func showBanner(isBusy: Bool, message: String, canCancel: Bool) {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = Banner(isBusy: isBusy, message: message, canCancel: canCancel)
    }

    private func showCompletionBanner(_ message: String) {
        bannerDismissTask?.cancel()
        banner = Banner(isBusy: false, message: message, canCancel: false)
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}
