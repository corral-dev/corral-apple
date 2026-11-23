import AppKit
import SwiftUI

// Only the transport and surrounding app environment are fixtures. The view,
// SwiftUI State/task lifecycle and automatic-start decision are production code.
struct RemoteCallError: Error { let message: String; var code = "" }

@Observable final class RemoteClient {
    enum ConnectionError: Error {
        case notConnected, handshakeFailed(String), sendFailed(String), timeout, invalidResponse, pairingRequired
    }
    var calls = 0
    var completed = 0
    var fails = false
    var running = false
    var awaitingSnapshot = false
    func call(_ method: String, params: [String: String]) async throws -> Bool {
        calls += 1
        try await Task.sleep(for: .milliseconds(50))
        if fails {
            throw RemoteCallError(message: "The development machine is still starting up.", code: "unavailable")
        }
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
    var mobileTerminalFontSize: Double = 11
}
struct SessionSummary { var key = "fixture"; var title = "Fixture"; var hosted = false; var live = false }
enum SessionPresentation { static func titleIcon(in title: String) -> String? { nil } }
struct SessionIdentityBackground: View {
    let title: String
    var body: some View { EmptyView() }
}
struct TerminalPromptTaskKey: Hashable { let request: UUID?; let stream: ObjectIdentifier?; let presented: Bool; let ready: Bool }
struct TerminalPromptRequest { var id = UUID(); var seq = 0; var generation = 0; var text: String? = nil }
enum TerminalPromptOutcome { case landed, superseded, absent, failed }
enum SessionActionsMenu {
    static func isReadonly(access: String) -> Bool { access == "readonly" }
    static func failureMessage(for error: Error) -> String { "Fixture failure" }
}
enum WireProtocol { static let mSessionResume = "session.resume" }
enum Space { static let md: CGFloat = 12 }
enum Radius { static let lg: CGFloat = 16 }
struct TerminalRGB: Hashable {
    var red: UInt8 = 255
    var green: UInt8 = 255
    var blue: UInt8 = 255
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
struct TerminalColorScheme {
    var backgroundRGB = TerminalRGB()
    static let dark = TerminalColorScheme()
    static let light = TerminalColorScheme()
    static func forAppearance(isDark: Bool) -> TerminalColorScheme { isDark ? .dark : .light }
}
@Observable final class RemoteTerminalStream {
    enum Phase: Equatable { case connecting, live, ended }
    static var instances: [RemoteTerminalStream] = []
    static var stopCalls = 0
    static var claimCalls = 0
    var phase = Phase.connecting
    var hasBeenLive = false
    var reveals: [(Int, Int)] = []
    let client: RemoteClient
    var clientIdentity: ObjectIdentifier? { ObjectIdentifier(client) }
    var isInFront: () -> Bool = { true }
    init(sessionKey: String, client: RemoteClient) {
        self.client = client
        Self.instances.append(self)
    }
    func start() {
        if client.awaitingSnapshot {
            phase = .connecting
        } else if client.running {
            phase = .live
            hasBeenLive = true
        } else {
            phase = .ended
        }
    }
    func stop() {
        Self.stopCalls += 1
    }
    func claimSize() {
        Self.claimCalls += 1
    }
    func navigatePrompt(seq: Int, historyGeneration: Int, text: String?) async -> TerminalPromptOutcome {
        reveals.append((seq, historyGeneration))
        return .landed
    }
}
@Observable final class ShellTerminalHost {
    static let fontSize: CGFloat = 11
    var appliedFontSize: CGFloat = 11
    var onFontSizeChange: ((Double) -> Void)?
    var hasScreen = false
    var currentBackgroundRGB: TerminalRGB?
    var presented = false
    var isShown = false
    init(fontSize: CGFloat = ShellTerminalHost.fontSize) {
        self.appliedFontSize = fontSize
    }
    func setPresented(_ value: Bool) {
        presented = value
        isShown = value
    }
    func applyFont(_ fontSize: CGFloat, onFontSizeChange: ((Double) -> Void)?) {
        self.onFontSizeChange = onFontSizeChange
        if presented {
            appliedFontSize = fontSize
        }
    }
    func simulatePinch(to fontSize: Double) {
        appliedFontSize = CGFloat(fontSize)
        onFontSizeChange?(fontSize)
    }
    func unbind() {}
}
@MainActor @Observable final class MobileTerminalSessions {
    @MainActor @Observable final class Terminal {
        fileprivate(set) var key: String
        let view: ShellTerminalHost
        private(set) var stream: RemoteTerminalStream
        var sampledBackground: TerminalRGB?
        var lastShown: UInt64 = 0
        init(key: String, client: RemoteClient, fontSize: CGFloat = ShellTerminalHost.fontSize) {
            self.key = key
            view = ShellTerminalHost(fontSize: fontSize)
            stream = RemoteTerminalStream(sessionKey: key, client: client)
            stream.start()
        }
        func replaceStream(client: RemoteClient) {
            stream.stop()
            stream = RemoteTerminalStream(sessionKey: key, client: client)
            stream.start()
        }
        func close() {
            stream.stop()
            view.unbind()
        }
    }
    var terminals: [String: Terminal] = [:]
    private var clock: UInt64 = 0
    func terminal(for key: String, client: RemoteClient?) -> Terminal? {
        guard let client, let terminal = terminals[key],
              terminal.stream.clientIdentity == ObjectIdentifier(client) else { return nil }
        return terminal
    }
    @discardableResult
    func open(_ key: String, client: RemoteClient, fontSize: CGFloat = ShellTerminalHost.fontSize) -> Terminal {
        clock &+= 1
        if let terminal = terminals[key] {
            if terminal.stream.clientIdentity != ObjectIdentifier(client) {
                terminal.replaceStream(client: client)
            }
            terminal.lastShown = clock
            return terminal
        }
        let terminal = Terminal(key: key, client: client, fontSize: fontSize)
        terminal.lastShown = clock
        terminals[key] = terminal
        return terminal
    }
    @discardableResult
    func restart(_ key: String, client: RemoteClient) -> Terminal {
        guard let terminal = terminals[key] else { return open(key, client: client) }
        clock &+= 1
        terminal.lastShown = clock
        terminal.replaceStream(client: client)
        return terminal
    }
    func close(_ key: String) { terminals.removeValue(forKey: key)?.close() }
    func migrate(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, let terminal = terminals.removeValue(forKey: oldKey) else { return }
        if terminals[newKey] != nil { terminal.close(); return }
        terminal.key = newKey
        terminals[newKey] = terminal
    }
}
struct RetainedShellTerminalView: View {
    let host: ShellTerminalHost
    var isPresented = true
    var sceneActive = true
    var allowsInput = true
    var isAgent = true
    var usesIdentityBackground = false
    var fontSize: CGFloat = ShellTerminalHost.fontSize
    var onFontSizeChange: ((Double) -> Void)? = nil
    var onBackgroundColorChange: ((TerminalRGB) -> Void)? = nil
    var body: some View {
        Text("Fixture retained terminal")
            .onAppear {
                host.setPresented(isPresented)
                host.applyFont(fontSize, onFontSizeChange: onFontSizeChange)
            }
            .onChange(of: isPresented) { _, next in
                host.setPresented(next)
                host.applyFont(fontSize, onFontSizeChange: onFontSizeChange)
            }
            .onChange(of: fontSize) { _, next in
                host.applyFont(next, onFontSizeChange: onFontSizeChange)
            }
            .onDisappear { host.setPresented(false) }
    }
}
@Observable final class Presentation {
    var mounted = true
    var presented = true
    var phase = ScenePhase.active
    var sessionKey: String?
    var prompt: TerminalPromptRequest?
}
struct Fixture: View {
    let model: AppModel
    let terminals: MobileTerminalSessions
    let session: SessionSummary
    let presentation: Presentation
    var body: some View {
        Group {
            if presentation.mounted {
                let effective = SessionSummary(
                    key: presentation.sessionKey ?? session.key,
                    title: session.title,
                    hosted: session.hosted,
                    live: session.live
                )
                AgentTerminalPane(
                    session: effective,
                    isPresented: presentation.presented,
                    promptRequest: presentation.prompt
                )
                .id(effective.key)
            }
        }
        .environment(model)
        .environment(terminals)
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
                         configure: (AppModel, MobileTerminalSessions, Presentation) -> Void = { _, _, _ in },
                         verify: (AppModel, MobileTerminalSessions, Presentation) -> Void) {
        RemoteTerminalStream.instances = []
        RemoteTerminalStream.stopCalls = 0
        RemoteTerminalStream.claimCalls = 0
        let model = AppModel()
        let terminals = MobileTerminalSessions()
        let presentation = Presentation()
        configure(model, terminals, presentation)
        let host = NSHostingView(rootView: Fixture(model: model, terminals: terminals, session: session, presentation: presentation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        settle()
        verify(model, terminals, presentation)
        window.close()
        settle(0.05)
        print("SCENARIO: \(name)")
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        scenario("stopped entry resumes once") { model, _, presentation in
            check(model.client?.calls == 1 && model.client?.completed == 1, "one uncancelled resume")
            check(RemoteTerminalStream.instances.last?.phase == .live, "resume attaches live terminal")
            presentation.presented = false; settle()
            presentation.presented = true; settle()
            check(model.client?.calls == 1, "reveal does not duplicate resume")
            RemoteTerminalStream.instances.last?.phase = .ended; settle()
            check(model.client?.calls == 1, "watched exit does not auto-restart")
        }
        scenario("stale hosted entry", session: SessionSummary(hosted: true)) { model, _, _ in
            check(model.client?.calls == 1 && model.client?.completed == 1, "ended first attach recovers once")
            check(RemoteTerminalStream.instances.last?.phase == .live, "stale attach replaced by live stream")
        }
        scenario("readonly", configure: { model, _, _ in model.connectedAccess = "readonly" }) { model, _, _ in
            check(model.client?.calls == 0, "readonly never resumes")
        }
        scenario("running elsewhere", session: SessionSummary(live: true)) { model, _, _ in
            check(model.client?.calls == 0, "external live agent never duplicated")
        }
        scenario("hidden", configure: { _, _, p in p.presented = false }) { model, _, p in
            check(model.client?.calls == 0, "hidden never resumes")
            p.presented = true; settle()
            check(model.client?.completed == 1, "foreground reveal resumes")
        }
        scenario("background", configure: { _, _, p in p.phase = .background }) { model, _, p in
            check(model.client?.calls == 0, "background never resumes")
            p.phase = .active; settle()
            check(model.client?.completed == 1, "scene activation resumes")
        }
        scenario("offline", configure: { model, _, _ in model.connectionState = .reconnecting }) { model, _, _ in
            check(model.client?.calls == 0, "offline never resumes")
            model.connectionState = .connected; settle()
            check(model.client?.completed == 1, "connection readiness resumes")
        }
        scenario("start failure self-heals with backoff", configure: { model, _, _ in model.client?.fails = true }) { model, _, _ in
            check(model.client?.calls == 1 && model.client?.completed == 0, "failure does not retry in a hot loop")
            model.client?.fails = false
            settle(0.6)
            check(model.client?.completed == 1 && RemoteTerminalStream.instances.last?.phase == .live,
                  "recoverable start failure self-heals automatically without user Retry")
        }
        scenario("prompt before stream creation", session: SessionSummary(hosted: true), configure: { model, _, p in
            model.client?.running = true
            model.connectionState = .reconnecting
            p.prompt = TerminalPromptRequest(seq: 41, generation: 7)
        }) { model, _, p in
            check(RemoteTerminalStream.instances.isEmpty, "pending prompt does not create an offline stream")
            model.connectionState = .connected; settle()
            let stream = RemoteTerminalStream.instances.last
            check(stream?.reveals.count == 1 && stream?.reveals.first?.0 == 41 && stream?.reveals.first?.1 == 7,
                  "stream creation retries pending sequence and generation")
            p.presented = false; settle()
            p.presented = true; settle()
            check(stream?.reveals.count == 1, "completed prompt does not replay on hide/show")
            p.prompt = TerminalPromptRequest(seq: 42, generation: 8); settle()
            check(stream?.reveals.count == 2 && stream?.reveals.last?.0 == 42 && stream?.reveals.last?.1 == 8,
                  "new selection reaches the retained pane")
        }
        scenario("prompt before first live snapshot", session: SessionSummary(hosted: true), configure: { model, _, p in
            model.client?.running = true
            model.client?.awaitingSnapshot = true
            p.prompt = TerminalPromptRequest(seq: 51, generation: 17)
        }) { _, _, _ in
            let stream = RemoteTerminalStream.instances.last
            check(stream?.reveals.isEmpty == true, "connecting pane does not consume the pending selection")
            stream?.phase = .live; stream?.hasBeenLive = true; settle()
            check(stream?.reveals.count == 1 && stream?.reveals.first?.0 == 51,
                  "first live snapshot retries the pending selection")
        }
        scenario("cold open survives split-column relocation", session: SessionSummary(hosted: true), configure: { model, _, _ in
            model.client?.running = true
            model.client?.awaitingSnapshot = true
        }) { _, _, p in
            check(RemoteTerminalStream.instances.count == 1, "cold open creates one stream")
            let stream = RemoteTerminalStream.instances[0]
            // Simulate NavigationSplitView unmounting during push relocation before snapshot arrives.
            p.mounted = false; settle(0.05)
            p.mounted = true; settle()
            check(RemoteTerminalStream.stopCalls == 0, "split relocation never stops connecting stream")
            check(RemoteTerminalStream.instances.count == 1, "relocated detail reuses same stream")
            stream.phase = .live; stream.hasBeenLive = true; settle()
            check(stream.phase == .live, "relocated terminal finishes connecting cleanly")
        }
        scenario("back and re-enter reuses live terminal without reconnect", session: SessionSummary(key: "session-a", hosted: true), configure: { model, _, _ in
            model.client?.running = true
        }) { model, terminals, p in
            check(RemoteTerminalStream.instances.count == 1, "initial open creates one stream")
            let firstTerminal = terminals.terminal(for: "session-a", client: model.client)
            check(firstTerminal != nil, "terminal exists on initial open")
            p.mounted = false; settle()
            check(RemoteTerminalStream.stopCalls == 0, "back navigation keeps terminal stream alive")
            p.mounted = true; settle()
            check(terminals.terminal(for: "session-a", client: model.client) === firstTerminal,
                  "re-entering session reuses exact Terminal instance")
            check(RemoteTerminalStream.instances.count == 1 && RemoteTerminalStream.stopCalls == 0,
                  "re-entering session reuses exact stream without reconnecting")
        }
        scenario("switch sessions A -> B -> A reuses A without reconnect", session: SessionSummary(key: "session-a", hosted: true), configure: { model, _, _ in
            model.client?.running = true
        }) { model, terminals, p in
            let termA = terminals.terminal(for: "session-a", client: model.client)
            check(termA != nil && RemoteTerminalStream.instances.count == 1, "session A opens once")
            p.sessionKey = "session-b"; settle()
            let termB = terminals.terminal(for: "session-b", client: model.client)
            check(termB != nil && RemoteTerminalStream.instances.count == 2, "session B opens once")
            check(RemoteTerminalStream.stopCalls == 0, "switching to B does not stop A")
            p.sessionKey = "session-a"; settle()
            check(terminals.terminal(for: "session-a", client: model.client) === termA, "returning to A keeps exact Terminal instance")
            check(RemoteTerminalStream.instances.count == 2 && RemoteTerminalStream.stopCalls == 0,
                  "A -> B -> A causes zero extra streams or stops")
        }
        scenario("key migration preserves single terminal", session: SessionSummary(key: "provisional:1", hosted: true), configure: { model, _, _ in
            model.client?.running = true
        }) { model, terminals, p in
            let original = terminals.terminal(for: "provisional:1", client: model.client)
            check(original != nil && RemoteTerminalStream.instances.count == 1, "provisional session opens one stream")
            terminals.migrate(from: "provisional:1", to: "canonical:1")
            p.sessionKey = "canonical:1"; settle()
            check(terminals.terminal(for: "canonical:1", client: model.client) === original,
                  "canonical key reuses migrated Terminal instance")
            check(RemoteTerminalStream.instances.count == 1 && RemoteTerminalStream.stopCalls == 0,
                  "migration opens no second stream")
        }
        scenario("terminal zoom persists across sessions", session: SessionSummary(key: "zoom-a", hosted: true), configure: { model, _, _ in
            model.client?.running = true
        }) { model, terminals, p in
            let termA = terminals.terminal(for: "zoom-a", client: model.client)
            check(termA?.view.appliedFontSize == 11, "session A starts at default font size")
            termA?.view.simulatePinch(to: 16.5)
            settle()
            check(model.mobileTerminalFontSize == 16.5, "pinch updates shared AppModel terminal font size")
            p.sessionKey = "zoom-b"; settle()
            let termB = terminals.terminal(for: "zoom-b", client: model.client)
            check(termB?.view.appliedFontSize == 16.5, "new session B opens directly at zoomed font size")
            termB?.view.simulatePinch(to: 19.0)
            settle()
            check(model.mobileTerminalFontSize == 19.0, "session B updates shared AppModel font size")
            p.sessionKey = "zoom-a"; settle()
            check(termA?.view.appliedFontSize == 19.0, "returning to retained session A applies updated shared font size")
        }
    }
}
