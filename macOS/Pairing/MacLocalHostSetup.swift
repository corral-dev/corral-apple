import Darwin
import Foundation
import Observation

/// Sets up the Corral host on this Mac from the pairing screen: find the CLI,
/// install it with Homebrew when missing, then pair through its own
/// `remote pair --json` link. Every step that changes the machine runs only
/// on an explicit user action. Unavailable inside the App Sandbox.
@MainActor
@Observable
final class MacLocalHostSetup {
    enum Step: Equatable {
        case installing
        case connecting
    }

    enum State: Equatable {
        case checking
        /// Already paired, or this build cannot run other programs.
        case hidden
        case ready(corral: URL)
        case needsInstall(brew: URL)
        case needsScriptInstall
        case needsHomebrew
        case running(Step)
        case failed(String)
    }

    private(set) var state: State = .checking
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isFixed = false
    @ObservationIgnored private var generation = 0

    init() {}

    #if DEBUG
    /// Inspection captures render one state without touching the machine.
    init(inspectionState: State) {
        state = inspectionState
        isFixed = true
    }
    #endif

    static let homebrewURL = URL(string: "https://brew.sh")!

    /// Read-only detection; never installs or starts anything.
    func refresh(pairedHostIDs: Set<String>) async {
        guard !isFixed else { return }
        guard !MacHostCommand.isSandboxed else {
            state = .hidden
            return
        }
        generation &+= 1
        let current = generation
        state = .checking
        if let corral = await MacHostCommand.locateCorral() {
            guard generation == current else { return }
            let hostID = await MacHostCommand.localHostID(corral: corral)
            guard generation == current else { return }
            state = hostID.map(pairedHostIDs.contains) == true ? .hidden : .ready(corral: corral)
        } else if let brew = MacHostCommand.locateHomebrew() {
            guard generation == current else { return }
            state = .needsInstall(brew: brew)
        } else if await MacHostCommand.hasScriptInstallPrerequisites() {
            guard generation == current else { return }
            state = .needsScriptInstall
        } else {
            guard generation == current else { return }
            state = .needsHomebrew
        }
    }

    func connect(corral: URL, appModel: AppModel, onPaired: @escaping @MainActor () -> Void) {
        state = .running(.connecting)
        start(onPaired: onPaired) { [weak self] in
            try await self?.pair(corral: corral, appModel: appModel)
        }
    }

    func install(brew: URL, appModel: AppModel, onPaired: @escaping @MainActor () -> Void) {
        state = .running(.installing)
        start(onPaired: onPaired) { [weak self] in
            try await MacHostCommand.installCorral(brew: brew)
            try Task.checkCancellation()
            guard let corral = await MacHostCommand.locateCorral() else {
                throw MacHostCommand.Failure.message(String(localized: "mac.pairing.corral_missing_after_install"))
            }
            try await self?.pair(corral: corral, appModel: appModel)
        }
    }

    func installWithScript(appModel: AppModel, onPaired: @escaping @MainActor () -> Void) {
        state = .running(.installing)
        start(onPaired: onPaired) { [weak self] in
            let target = MacHostCommand.appMarketingVersion
            try await MacHostCommand.installCorralWithScript(version: target)
            try Task.checkCancellation()
            guard let corral = await MacHostCommand.locateCorral() else {
                throw MacHostCommand.Failure.message(String(localized: "mac.pairing.corral_missing_after_install"))
            }
            try await self?.pair(corral: corral, appModel: appModel)
        }
    }

    /// Stops the running Homebrew or pairing process and everything it started.
    func cancel(pairedHostIDs: Set<String>) {
        task?.cancel()
        task = nil
        generation &+= 1
        Task { await refresh(pairedHostIDs: pairedHostIDs) }
    }

    private func start(onPaired: @escaping @MainActor () -> Void,
                       _ work: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        generation &+= 1
        let current = generation
        task = Task { [weak self] in
            let outcome: Result<Void, Error>
            do {
                try await work()
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            // A cancelled or superseded run never overwrites the newer state.
            guard let self, self.generation == current else { return }
            self.task = nil
            switch outcome {
            case .success:
                self.state = .hidden
                onPaired()
            case .failure(let error) where !(error is CancellationError):
                self.state = .failed(error.localizedDescription)
            case .failure:
                break
            }
        }
    }

    private func pair(corral: URL, appModel: AppModel) async throws {
        state = .running(.connecting)
        let link = try await MacHostCommand.pairingLink(corral: corral)
        let payload = try PairingPayload.parse(string: link)
        do {
            _ = try await appModel.completePairing(payload, deviceName: UIDeviceName.current)
        } catch is CancellationError {
            // Superseded by the window's own connection once the machine appears.
        }
    }
}

/// Runs the host CLI and Homebrew outside the main actor. GUI apps inherit a
/// minimal PATH, so known install locations are searched before a bounded
/// login-shell lookup.
nonisolated enum MacHostCommand {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): text
            }
        }
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    static var appMarketingVersion: String {
        let raw = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        return CLIVersionSyncPolicy.normalizedVersion(raw)
    }

    static func locateHomebrew() -> URL? {
        homebrewPrefixes.map { URL(fileURLWithPath: $0).appending(path: "bin/brew") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Resolves known install locations first; when multiple copies coexist
    /// (for example `~/.local/bin/corral` alongside Homebrew), asks the
    /// interactive login shell so developer checkouts keep precedence.
    static func locateCorral() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known = [home.appending(path: ".local/bin/corral")]
            + homebrewPrefixes.map { URL(fileURLWithPath: $0).appending(path: "bin/corral") }
        let hits = known.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        if hits.count == 1 {
            return hits[0]
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let output = try? await run(URL(fileURLWithPath: shell), ["-ilc", "command -v corral"], timeout: 5),
           output.status == 0,
           let path = String(data: output.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).last.map(String.init),
           path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return hits.first
    }

    static func inspectCorral(corral: URL) async -> (snapshot: CLIStatusSnapshot?, supportsVersionFlag: Bool) {
        if let output = try? await run(corral, ["update", "--status", "--json"], timeout: 10),
           output.status == 0,
           let snapshot = CLIVersionSyncPolicy.parseCLIStatusJSON(output.stdout) {
            return (snapshot, true)
        }
        guard let output = try? await run(corral, ["--version"], timeout: 10),
              output.status == 0 else {
            return (nil, false)
        }
        let combined = String(data: output.stdout + output.stderr, encoding: .utf8) ?? ""
        guard let version = CLIVersionSyncPolicy.parsePlainVersionOutput(combined) else {
            return (nil, false)
        }
        let resolved = corral.resolvingSymlinksInPath().path
        let channel: CLIChannel?
        if resolved.contains("/Cellar/") || resolved.contains("/homebrew/") || resolved.contains("/linuxbrew/") {
            channel = .brew
        } else if resolved.contains("pipx/venvs") {
            channel = .pipx
        } else {
            channel = nil
        }
        return (CLIStatusSnapshot(version: version, channel: channel, editableLike: false), false)
    }

    static func hasScriptInstallPrerequisites() async -> Bool {
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        guard let whichCurl = try? await run(envURL, ["which", "curl"], timeout: 5), whichCurl.status == 0,
              let whichTmux = try? await run(envURL, ["which", "tmux"], timeout: 5), whichTmux.status == 0,
              let pyCheck = try? await run(
                envURL,
                ["python3", "-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)"],
                timeout: 5
              ) else {
            return false
        }
        return pyCheck.status == 0
    }

    static func installCorral(brew: URL) async throws {
        let output = try await run(
            brew,
            ["install", "x0c/tap/corral"],
            timeout: nil,
            extraEnv: ["CORRAL_UPDATE_NO_MAC": "1"],
            unsetEnv: ["HOMEBREW_NO_AUTO_UPDATE"]
        )
        guard output.status == 0 else {
            throw Failure.message(lastLine(output.stderr) ?? lastLine(output.stdout) ?? String(localized: "error.unknown"))
        }
    }

    static func installCorralWithScript(version: String) async throws {
        let target = CLIVersionSyncPolicy.normalizedVersion(version)
        let script = """
        curl -fsSL "https://raw.githubusercontent.com/corral-dev/corral/v$1/install.sh" | bash
        """
        let output = try await run(
            URL(fileURLWithPath: "/bin/bash"),
            ["-c", script, "--", target],
            timeout: 600,
            extraEnv: ["CORRAL_VERSION": "v\(target)", "CORRAL_UPDATE_NO_MAC": "1"]
        )
        guard output.status == 0 else {
            throw Failure.message(lastLine(output.stderr) ?? lastLine(output.stdout) ?? String(localized: "error.unknown"))
        }
    }

    static func upgradeCorral(
        corral: URL,
        targetVersion: String,
        channel: CLIChannel?,
        viaVersionFlag: Bool
    ) async throws {
        let target = CLIVersionSyncPolicy.normalizedVersion(targetVersion)
        if viaVersionFlag {
            let output = try await run(
                corral,
                ["update", "--version", target, "--no-mac", "--json"],
                timeout: 300,
                extraEnv: ["CORRAL_UPDATE_NO_MAC": "1"],
                unsetEnv: ["HOMEBREW_NO_AUTO_UPDATE"]
            )
            if output.status == 0 {
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
               let msg = obj["message"] as? String, !msg.isEmpty {
                throw Failure.message(msg)
            }
            throw Failure.message(lastLine(output.stderr) ?? lastLine(output.stdout) ?? String(localized: "error.unknown"))
        }
        if channel == .brew, let brew = locateHomebrew() {
            _ = try? await run(
                brew, ["update"], timeout: 120,
                extraEnv: ["CORRAL_UPDATE_NO_MAC": "1"],
                unsetEnv: ["HOMEBREW_NO_AUTO_UPDATE"]
            )
            let upgrade = try await run(
                brew, ["upgrade", "x0c/tap/corral"], timeout: 600,
                extraEnv: ["CORRAL_UPDATE_NO_MAC": "1"],
                unsetEnv: ["HOMEBREW_NO_AUTO_UPDATE"]
            )
            guard upgrade.status == 0 else {
                throw Failure.message(lastLine(upgrade.stderr) ?? lastLine(upgrade.stdout) ?? String(localized: "error.unknown"))
            }
            return
        }
        let fallback = try await run(
            corral, ["update"], timeout: 300,
            extraEnv: ["CORRAL_UPDATE_NO_MAC": "1"],
            unsetEnv: ["HOMEBREW_NO_AUTO_UPDATE"]
        )
        guard fallback.status == 0 else {
            throw Failure.message(lastLine(fallback.stderr) ?? lastLine(fallback.stdout) ?? String(localized: "error.unknown"))
        }
    }

    static func restartLocalRemoteIfOutdated(corral: URL, targetVersion: String) async {
        guard let output = try? await run(corral, ["remote", "status", "--json"], timeout: 10),
              output.status == 0,
              let data = try? envelopeData(output.stdout) else {
            return
        }
        let running = (data["running"] as? Bool) == true
        let wanted = (data["wanted"] as? Bool) == true
        guard running, wanted else { return }
        let hostVersion = data["version"] as? String
        let outdated = hostVersion.flatMap {
            CLIVersionSyncPolicy.compareVersions($0, targetVersion) == .orderedAscending
        } ?? true
        guard outdated else { return }
        _ = try? await run(corral, ["remote", "on", "--force", "--json"], timeout: 30)
    }

    /// This machine's host ID when its remote service has one; nil otherwise.
    static func localHostID(corral: URL) async -> String? {
        guard let output = try? await run(corral, ["remote", "status", "--json"], timeout: 20),
              let data = try? envelopeData(output.stdout) else { return nil }
        return (data["host_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Grants only an explicitly chosen local folder, guarded by the host identity.
    static func allowProject(_ folder: URL, hostID: String, corral: URL) async throws -> String {
        let output = try await run(corral, ["remote", "allow-project", folder.path,
                                          "--host-id", hostID, "--json"], timeout: 20)
        let data = try envelopeData(output.stdout, fallback: output.stderr)
        guard output.status == 0, data["host_id"] as? String == hostID,
              let path = data["path"] as? String, !path.isEmpty else {
            throw Failure.message(String(localized: "error.unknown"))
        }
        return path
    }

    /// Turns the remote service on (it registers its own login autostart) and
    /// returns a fresh pairing link.
    static func pairingLink(corral: URL) async throws -> String {
        let output = try await run(corral, ["remote", "pair", "--json"], timeout: 300)
        let data = try envelopeData(output.stdout, fallback: output.stderr)
        guard let url = data["url"] as? String, !url.isEmpty else {
            throw Failure.message(lastLine(output.stderr) ?? String(localized: "error.unknown"))
        }
        return url
    }

    /// The `data` object of the CLI's JSON envelope, or its error message.
    private static func envelopeData(_ stdout: Data, fallback: Data = Data()) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw Failure.message(lastLine(fallback) ?? lastLine(stdout) ?? String(localized: "error.unknown"))
        }
        if object["ok"] as? Bool == true, let data = object["data"] as? [String: Any] {
            return data
        }
        let message = (object["error"] as? [String: Any])?["message"] as? String
        throw Failure.message(message ?? String(localized: "error.unknown"))
    }

    private static func lastLine(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Runs a program to completion; cancelling the task terminates it.
    ///
    /// Pipes are drained with non-blocking `availableData` polling instead of
    /// `readDataToEndOfFile`: a child that inherits the pipes (Homebrew build
    /// steps do) would otherwise hold EOF open forever after the parent exits.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval?,
        extraEnv: [String: String] = [:],
        unsetEnv: [String] = []
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in unsetEnv {
            environment.removeValue(forKey: key)
        }
        let searchPath = homebrewPrefixes.flatMap { ["\($0)/bin", "\($0)/sbin"] }
            + [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
               "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = searchPath.joined(separator: ":")
        for (key, value) in extraEnv {
            environment[key] = value
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let timer = timeout.map { seconds in
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                if process.isRunning { terminateTree(process.processIdentifier) }
            }
        }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            var outData = Data(), errData = Data()
            let outHandle = stdout.fileHandleForReading, errHandle = stderr.fileHandleForReading
            while process.isRunning {
                try Task.checkCancellation()
                outData += outHandle.availableData
                errData += errHandle.availableData
                try? await Task.sleep(for: .milliseconds(50))
            }
            await Task.detached { process.waitUntilExit() }.value
            try Task.checkCancellation()
            // Trailing output grace: two short windows, then whatever arrived.
            for _ in 0..<4 {
                outData += outHandle.availableData
                errData += errHandle.availableData
                try? await Task.sleep(for: .milliseconds(50))
            }
            outData += outHandle.availableData
            errData += errHandle.availableData
            try? outHandle.close()
            try? errHandle.close()
            return Output(status: process.terminationStatus, stdout: outData, stderr: errData)
        } onCancel: {
            if process.isRunning { terminateTree(process.processIdentifier) }
        }
    }

    /// Homebrew starts downloads and builds as child processes that would keep
    /// running (and keep the output pipes open) after only the parent stops.
    /// Children first, so none is reparented before it is signalled; survivors
    /// get SIGKILL after a grace period. Never signals PID 1 or ourselves.
    static func terminateTree(_ pid: pid_t) {
        guard pid > 1, pid != getpid() else { return }
        var tree = [pid]
        collectTree(pid, into: &tree)
        for member in tree { kill(member, SIGTERM) }
        usleep(500_000)
        for member in tree where kill(member, 0) == 0 { kill(member, SIGKILL) }
    }

    private static func collectTree(_ pid: pid_t, into tree: inout [pid_t]) {
        for child in childProcesses(of: pid) {
            tree.append(child)
            collectTree(child, into: &tree)
        }
    }

    private static func childProcesses(of pid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / stride)
            .filter { $0.kp_eproc.e_ppid == pid }
            .map(\.kp_proc.p_pid)
    }
}
