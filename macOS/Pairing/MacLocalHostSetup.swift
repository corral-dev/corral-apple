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
        case needsHomebrew
        case running(Step)
        case failed(String)
    }

    private(set) var state: State = .checking
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isFixed = false

    init() {}

    #if DEBUG
    /// Inspection captures render one state without touching the machine.
    init(inspectionState: State) {
        state = inspectionState
        isFixed = true
    }
    #endif

    static let homebrewURL = URL(string: "https://brew.sh")!
    static let installGuideURL = URL(string: "https://github.com/corral-dev/corral#install")!

    /// Read-only detection; never installs or starts anything.
    func refresh(pairedHostIDs: Set<String>) async {
        guard !isFixed else { return }
        guard !MacHostCommand.isSandboxed else {
            state = .hidden
            return
        }
        state = .checking
        if let corral = await MacHostCommand.locateCorral() {
            let hostID = await MacHostCommand.localHostID(corral: corral)
            state = hostID.map(pairedHostIDs.contains) == true ? .hidden : .ready(corral: corral)
        } else if let brew = MacHostCommand.locateHomebrew() {
            state = .needsInstall(brew: brew)
        } else {
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

    /// Stops the running Homebrew or pairing process.
    func cancel(pairedHostIDs: Set<String>) {
        task?.cancel()
        task = nil
        Task { await refresh(pairedHostIDs: pairedHostIDs) }
    }

    private func start(onPaired: @escaping @MainActor () -> Void,
                       _ work: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            do {
                try await work()
                self?.state = .hidden
                onPaired()
            } catch is CancellationError {
                // `cancel` already refreshes the state.
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.task = nil
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

    static func locateHomebrew() -> URL? {
        homebrewPrefixes.map { URL(fileURLWithPath: $0).appending(path: "bin/brew") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The `corral` the user runs in Terminal (interactive login shell, which
    /// reads the same startup files as Terminal) wins, so the
    /// app never switches a working setup to another copy; known install
    /// locations cover shells that fail or time out.
    static func locateCorral() async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let output = try? await run(URL(fileURLWithPath: shell), ["-ilc", "command -v corral"], timeout: 5),
           output.status == 0,
           let path = String(data: output.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).last.map(String.init),
           path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known = homebrewPrefixes.map { URL(fileURLWithPath: $0).appending(path: "bin/corral") }
            + [home.appending(path: ".local/bin/corral")]
        return known.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// This machine's host ID when its remote service has one; nil otherwise.
    static func localHostID(corral: URL) async -> String? {
        guard let output = try? await run(corral, ["remote", "status", "--json"], timeout: 20),
              let data = try? envelopeData(output.stdout) else { return nil }
        return (data["host_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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

    static func installCorral(brew: URL) async throws {
        let output = try await run(brew, ["install", "x0c/tap/corral"], timeout: nil)
        guard output.status == 0 else {
            throw Failure.message(lastLine(output.stderr) ?? lastLine(output.stdout) ?? String(localized: "error.unknown"))
        }
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
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval?) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let searchPath = homebrewPrefixes.flatMap { ["\($0)/bin", "\($0)/sbin"] }
            + [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
               "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = searchPath.joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let timer = timeout.map { seconds in
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                if process.isRunning { process.terminate() }
            }
        }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently so a full buffer cannot stall the child.
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            let (outData, errData) = await (out, err)
            await Task.detached { process.waitUntilExit() }.value
            try Task.checkCancellation()
            return Output(status: process.terminationStatus, stdout: outData, stderr: errData)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
