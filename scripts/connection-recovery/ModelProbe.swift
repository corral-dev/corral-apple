import Foundation

// UI dependencies are irrelevant to the connection owner under test.
enum ChatMarkdown { static func prewarm() {} }
struct ChatDiagramRenderer {
    static let shared = ChatDiagramRenderer()
    func forget(host: String) {}
}
enum SessionTextSize: String { case standard; static let storageKey = "corral.sessionTextSize"; static func resolve(stored: String?) -> Self { .standard } }

@main @MainActor
struct ModelProbe {
    static func main() async throws {
        let model = AppModel()
        let remote = RemoteClient(devicePrivateKey: Data(repeating: 4, count: 32))
        defer { model.disconnect(); remote.disconnect() }
        _ = remote.installPlaneForTesting(isControl: true)
        model.observeConnectionForTesting(remote, hostID: "fixture-a")
        try await Task.sleep(for: .milliseconds(350))
        precondition(model.connectionState != .connected, "transport-only connection leaked into UI")
        remote.confirmedAccess = "readonly"
        remote.controlConfirmed = true
        remote.notifyReadyHandlers()
        precondition(model.connectionState == .connected)
        precondition(model.connectedHostID == "fixture-a")
        precondition(model.connectedAccess == "readonly")
        model.selectHost(HostInfo(hostID: "fixture-b", name: "B", publicKeyHex: ""))
        remote.notifyReadyHandlers()
        precondition(model.connectedHostID == "fixture-a", "selection relabelled connection")
        remote.disconnect()
        remote.terminalConnectionError = "Pairing revoked"
        try await Task.sleep(for: .milliseconds(350))
        precondition(model.connectionState == .failed("Pairing revoked"))
        precondition(model.connectedAccess == nil)
        print("PASS AppModel: confirmation boundary, readonly access, captured identity, revoked pairing")
    }
}
