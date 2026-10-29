#if DEBUG
import Foundation

/// Real host, real pane, no assistant input: lose a resync acknowledgement
/// after its complete screen arrives, then replace only the data connection.
@MainActor
enum MacTerminalRecoveryInspection {
    private static var started = false

    static func runIfRequested(stream: RemoteTerminalStream, client: RemoteClient?) {
        guard !started, ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalRecovery"),
              let client else { return }
        started = true
        Task { await run(stream: stream, client: client) }
    }

    private static func run(stream: RemoteTerminalStream, client: RemoteClient) async {
        var result: [String: Bool] = [:]
        result["initial_live"] = await wait { stream.phase == .live && visible(stream) }
        guard result["initial_live"] == true else { save(result); return }
        let revision = stream.inspectionSnapshotRevision
        var injected = false
        stream.inspectionReply = { operation in
            guard operation == .resync, !injected else { return }
            injected = true
            // Deliberately ignore cancellation to exercise the late-reply race.
            try? await Task.sleep(for: .milliseconds(500))
            throw RemoteClient.ConnectionError.timeout
        }
        stream.inspectionHandle(["resync": true])
        result["fresh_snapshot"] = await wait { stream.inspectionSnapshotRevision > revision && stream.phase == .live }
        try? await Task.sleep(for: .seconds(1))
        result["late_timeout_keeps_live"] = injected && stream.phase == .live && visible(stream)
        stream.inspectionReply = nil
        save(result)

        let generation = stream.inspectionEpoch
        client.inspectionFailDataPlane()
        result["data_rebind_restores_terminal"] = await wait {
            client.diagnosticState.dataAttached && stream.inspectionEpoch != generation
                && stream.phase == .live && visible(stream)
        }
        result["no_agent_input"] = stream.input.revision == 0
        save(result)
        // Keep the actual recovered pane available for an isolated window capture.
        try? await Task.sleep(for: .seconds(60))
    }

    private static func visible(_ stream: RemoteTerminalStream) -> Bool {
        guard let view = stream.sink as? TerminalHostView else { return false }
        return view.isShown && view.hasScreen && view.window != nil
    }

    private static func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func save(_ result: [String: Bool]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-terminal-recovery-acceptance.json"), options: .atomic)
    }
}
#endif
