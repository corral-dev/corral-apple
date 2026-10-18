import AppKit
import SwiftUI

// Only the transport and surrounding app environment are fixtures. The view,
// SwiftUI State/task lifecycle and automatic-start decision are production code.
@Observable final class RemoteClient {
    var calls = 0
    var completed = 0
    var fails = false
    var running = false
    func call(_ method: String, params: [String: String]) async throws -> Bool {
        calls += 1
        try await Task.sleep(for: .milliseconds(50))
        if fails { throw NSError(domain: "fixture", code: 1) }
        running = true
        completed += 1
        return true
    }
}
@Observable final class AppModel {
    enum ConnectionState { case connected, reconnecting }
    var client: RemoteClient? = RemoteClient()
    var clientIdentity: ObjectIdentifier? { client.map(ObjectIdentifier.init) }
    var connectionState = ConnectionState.connected
    var connectedAccess = "full"
}
struct SessionSummary { var key = "fixture"; var hosted = false; var live = false }
struct TerminalPromptTaskKey: Hashable { let request: UUID?; let stream: ObjectIdentifier?; let presented: Bool }
struct TerminalPromptRequest { var id = UUID(); var seq = 0; var generation = 0 }
enum SessionActionsMenu {
    static func isReadonly(access: String) -> Bool { access == "readonly" }
    static func failureMessage(for error: Error) -> String { "Fixture failure" }
}
enum WireProtocol { static let mSessionResume = "session.resume" }
enum Space { static let md: CGFloat = 12 }
enum Radius { static let lg: CGFloat = 16 }
struct RGB { var red = 255; var green = 255; var blue = 255 }
struct TerminalColorScheme {
    var background = RGB()
    static let dark = TerminalColorScheme()
    static let light = TerminalColorScheme()
}
@Observable final class RemoteTerminalStream {
    enum Phase: Equatable { case connecting, live, ended, failed(String) }
    static var instances: [RemoteTerminalStream] = []
    var phase = Phase.connecting
    let client: RemoteClient
    var clientIdentity: ObjectIdentifier? { ObjectIdentifier(client) }
    var isInFront: () -> Bool = { true }
    init(sessionKey: String, client: RemoteClient) {
        self.client = client
        Self.instances.append(self)
    }
    func start() { phase = client.running ? .live : .ended }
    func stop() {}
    func retry() { start() }
    func navigatePrompt(seq: Int, historyGeneration: Int) async -> String? { nil }
}
struct ShellTerminalView: View {
    let stream: RemoteTerminalStream
    let isPresented: Bool
    let allowsInput: Bool
    let isAgent: Bool
    var body: some View { Text("Fixture terminal") }
}
@Observable final class Presentation {
    var presented = true
    var phase = ScenePhase.active
}
struct Fixture: View {
    let model: AppModel
    let session: SessionSummary
    let presentation: Presentation
    var body: some View {
        AgentTerminalPane(session: session, isPresented: presentation.presented)
            .environment(model)
            .environment(\.scenePhase, presentation.phase)
    }
}
@main struct Probe {
    static func settle(_ duration: TimeInterval = 0.35) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }
    static func scenario(_ name: String, session: SessionSummary = SessionSummary(),
                         configure: (AppModel, Presentation) -> Void = { _, _ in },
                         verify: (AppModel, Presentation) -> Void) {
        RemoteTerminalStream.instances = []
        let model = AppModel()
        let presentation = Presentation()
        configure(model, presentation)
        let host = NSHostingView(rootView: Fixture(model: model, session: session, presentation: presentation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        settle()
        verify(model, presentation)
        window.close()
        settle(0.05)
        print("SCENARIO: \(name)")
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        scenario("stopped entry resumes once") { model, presentation in
            check(model.client?.calls == 1 && model.client?.completed == 1, "one uncancelled resume")
            check(RemoteTerminalStream.instances.last?.phase == .live, "resume attaches live terminal")
            presentation.presented = false; settle()
            presentation.presented = true; settle()
            check(model.client?.calls == 1, "reveal does not duplicate resume")
            RemoteTerminalStream.instances.last?.phase = .ended; settle()
            check(model.client?.calls == 1, "watched exit does not auto-restart")
        }
        scenario("stale hosted entry", session: SessionSummary(hosted: true)) { model, _ in
            check(model.client?.calls == 1 && model.client?.completed == 1, "ended first attach recovers once")
            check(RemoteTerminalStream.instances.last?.phase == .live, "stale attach replaced by live stream")
        }
        scenario("readonly", configure: { model, _ in model.connectedAccess = "readonly" }) { model, _ in
            check(model.client?.calls == 0, "readonly never resumes")
        }
        scenario("running elsewhere", session: SessionSummary(live: true)) { model, _ in
            check(model.client?.calls == 0, "external live agent never duplicated")
        }
        scenario("hidden", configure: { _, p in p.presented = false }) { model, p in
            check(model.client?.calls == 0, "hidden never resumes")
            p.presented = true; settle()
            check(model.client?.completed == 1, "foreground reveal resumes")
        }
        scenario("background", configure: { _, p in p.phase = .background }) { model, p in
            check(model.client?.calls == 0, "background never resumes")
            p.phase = .active; settle()
            check(model.client?.completed == 1, "scene activation resumes")
        }
        scenario("offline", configure: { model, _ in model.connectionState = .reconnecting }) { model, _ in
            check(model.client?.calls == 0, "offline never resumes")
            model.connectionState = .connected; settle()
            check(model.client?.completed == 1, "connection readiness resumes")
        }
        scenario("start failure", configure: { model, _ in model.client?.fails = true }) { model, _ in
            check(model.client?.calls == 1 && model.client?.completed == 0, "failure does not retry in a loop")
        }
    }
}
