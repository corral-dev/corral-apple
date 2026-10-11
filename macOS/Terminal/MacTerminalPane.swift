import SwiftUI

/// Terminal view of one pane: the agent's own TUI, live from the host.
/// Opening it on a session that is not running starts the session natively;
/// only an agent the user quit while watching offers Return to restart.
struct MacTerminalPane: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    let session: SessionSummary
    let isFocused: Bool

    @State private var stream: RemoteTerminalStream?
    @State private var isStarting = false
    @State private var startAttempted = false
    @State private var startError: String?
    @State private var sawLive = false

    var body: some View {
        Group {
            if let startError {
                startFailure(startError)
            } else if runsElsewhere {
                runningElsewhereNote
            } else if showsRestartPrompt {
                restartPrompt
            } else if isStarting {
                waitingIndicator
            } else if let stream {
                content(stream)
            } else {
                waitingIndicator
            }
        }
        .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: TerminalAppearance.background))
        .task(id: isReady && needsStart) {
            guard isReady, needsStart else { return }
            // Unstructured: starting clears `needsStart`, which would cancel
            // this task and drop the host's resume response.
            Task { await start() }
        }
        .onChange(of: stream?.phase) { _, phase in
            if phase == .live { sawLive = true }
        }
        .task(id: PaneConnectionKey(sessionKey: session.key, client: appModel.clientIdentity, ready: isReady && session.hosted)) {
            guard isReady, session.hosted else { return }
            startIfNeeded()
            #if DEBUG
            await inspectAppearanceFlipIfRequested()
            await inspectTypingIfRequested()
            #endif
        }
        .onDisappear {
            stream?.stop()
            stream = nil
        }
    }

    /// Opening the view starts a session that is not running, once. A stream
    /// that ends before it ever went live is the same opening (stale summary).
    private var needsStart: Bool {
        guard !startAttempted, !isStarting, startError == nil else { return false }
        if let stream { return stream.phase == .ended && !sawLive }
        return !session.hosted && !session.live
    }

    /// Running in another terminal window: a second process would write the
    /// same history, so the pane never starts one on its own.
    private var runsElsewhere: Bool {
        stream == nil && !isStarting && session.live && !session.hosted
    }

    /// Only after the agent ended under an attempted start or while watched:
    /// relaunching on its own would undo the user's exit. Any other stream
    /// stays mounted (it reports its grid while attaching), whatever the
    /// possibly stale list summary says.
    private var showsRestartPrompt: Bool {
        guard !isStarting, let stream, stream.phase == .ended else { return false }
        return sawLive || startAttempted
    }

    @ViewBuilder
    private func content(_ stream: RemoteTerminalStream) -> some View {
        if case .failed(let error) = stream.phase {
            ContentUnavailableView {
                Label("terminal.load_failed.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("action.retry") { stream.retry() }
            }
        } else {
            // Clicks focus the pane through the window's click monitor (MacRootView).
            TerminalEmulator(stream: stream, isFocusedPane: isFocused)
            .overlay {
                if stream.phase == .connecting || Self.inspectWaiting {
                    waitingIndicator
                }
            }
        }
    }

    #if DEBUG
    /// `-CorralInspectTerminalWaiting` keeps the waiting indicator up for captures.
    private static let inspectWaiting = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalWaiting")
    #else
    private static let inspectWaiting = false
    #endif

    /// Shown until the host's first frame arrives, and over the last frame
    /// while the connection recovers: a terminal pane is otherwise blank.
    private var waitingIndicator: some View {
        ProgressView {
            Text(appModel.connectionState == .reconnecting ? "connection.reconnecting" : "connection.connecting")
        }
        .interfaceControlSize(.small)
        .interfacePadding(.horizontal, Space.base)
        .interfacePadding(.vertical, Space.md)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.lg * interfaceScale))
    }

    private func startFailure(_ error: String) -> some View {
        ContentUnavailableView {
            Label("terminal.start_failed.title", systemImage: "exclamationmark.triangle")
        } description: {
            Text(verbatim: error)
        } actions: {
            Button("action.retry") {
                self.startError = nil
                Task { await start() }
            }
        }
    }

    private var runningElsewhereNote: some View {
        ContentUnavailableView {
            Label("terminal.running_elsewhere.title", systemImage: "macwindow.on.rectangle")
        } description: {
            Text("terminal.running_elsewhere.description")
        }
    }

    private var restartPrompt: some View {
        VStack(spacing: Space.md * interfaceScale) {
            Image(systemName: "terminal")
                .interfaceFont(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text("terminal.not_running.title")
                .interfaceFont(.headline)
            Text("terminal.not_running.description")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("terminal.restart") { Task { await start() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isStarting)
        }
        .interfacePadding(Space.xxl)
    }

    private func start() async {
        guard !isStarting else { return }
        startAttempted = true
        isStarting = true
        defer { isStarting = false }
        if let error = await workspace.resumeInPane(session.key) {
            #if DEBUG
            debugTrace("terminal start failed: \(error)")
            #endif
            startError = error
            return
        }
        stream?.stop()
        stream = nil
        sawLive = false
        startIfNeeded()
        #if DEBUG
        debugTrace("terminal started session; phase=\(String(describing: stream?.phase))")
        #endif
    }

    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }

    private func startIfNeeded() {
        guard let client = appModel.client else { return }
        if let stream, stream.clientIdentity != ObjectIdentifier(client) {
            stream.stop()
            self.stream = nil
        }
        if stream == nil {
            stream = RemoteTerminalStream(sessionKey: session.key, client: client)
        }
        stream?.start()
    }

    #if DEBUG
    /// Debug-only: `-CorralInspectAppearanceFlip` switches the app to the other
    /// appearance after the terminal is live, so a capture shows the live switch
    /// and the trace log shows the host acknowledging the new colours.
    private func inspectAppearanceFlipIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectAppearanceFlip") else { return }
        try? await Task.sleep(for: .seconds(8))
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        debugTrace("inspection flipped appearance to \(dark ? "light" : "dark")")
    }

    /// Debug-only: types `CORRAL_INSPECTION_TERMINAL_TYPE` into the disposable
    /// acceptance session through the same sender real keystrokes use, holds it
    /// for a capture, then erases it with Backspace (never submits).
    private func inspectTypingIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["CORRAL_INSPECTION_TERMINAL_TYPE"], !text.isEmpty,
              SessionPresentation.fullWorkspacePath(from: session).contains("corral-phone-acceptance") else { return }
        try? await Task.sleep(for: .seconds(3))
        for character in text {
            stream?.input.send(ArraySlice(Array(String(character).utf8)))
        }
        try? await Task.sleep(for: .seconds(8))
        stream?.input.send(ArraySlice(Array(repeating: UInt8(0x7f), count: text.count)))
    }
    #endif
}
