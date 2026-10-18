import SwiftUI

/// Terminal view of one pane: the agent's own TUI, live from the host.
/// Opening it on a session that is not running starts the session natively;
/// only an agent the user quit while watching offers Return to restart.
struct MacTerminalPane: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.macPaneLifetime) private var lifetime
    let session: SessionSummary
    let isFocused: Bool
    let isPresented: Bool
    var promptRequest: TerminalPromptRequest? = nil

    @State private var stream: RemoteTerminalStream?
    @State private var isStarting = false
    @State private var startAttempted = false
    @State private var startError: String?
    @State private var sawLive = false
    @State private var handledPromptRequest: UUID?

    var body: some View {
        // The emulator keeps one structural position for its whole life and
        // hides natively while chat or another session is shown; SwiftUI
        // chrome is drawn only while presented, so nothing covers the chat.
        ZStack {
            if let stream, showsEmulator(stream) {
                // Clicks focus the pane through the window's click monitor (MacRootView).
                TerminalEmulator(stream: stream, isFocusedPane: isFocused,
                                 isPresented: isPresented)
                    .chatReadableColumn()
            }
            if isPresented { status }
        }
        .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isPresented { Color(nsColor: TerminalAppearance.background) }
        }
        .task(id: isPresented && isReady && needsStart) {
            guard isPresented, isReady, needsStart else { return }
            // Detached so that flipping needsStart (startAttempted = true)
            // does not cancel the in-flight resume: the guards inside re-check
            // presentation, client and session before touching the host.
            let key = session.key
            let clientID = appModel.clientIdentity
            Task { @MainActor in
                guard isPresented, isReady, session.key == key,
                      appModel.clientIdentity == clientID, needsStart else { return }
                await start()
            }
        }
        .onChange(of: stream?.phase) { _, phase in
            if phase == .live { sawLive = true }
        }
        .task(id: PaneConnectionKey(sessionKey: session.key, client: appModel.clientIdentity, ready: isPresented && isReady && session.hosted)) {
            guard isPresented, isReady, session.hosted else { return }
            startIfNeeded()
            #if DEBUG
            if let stream {
                MacTerminalReturnInspection.runIfRequested(
                    workspace: workspace, session: session, stream: stream)
            }
            await inspectAppearanceFlipIfRequested()
            await inspectTypingIfRequested()
            #endif
        }
        .task(id: TerminalPromptTaskKey(request: promptRequest?.id, stream: stream.map(ObjectIdentifier.init),
                                         presented: isPresented)) {
            guard isPresented, let request = promptRequest, handledPromptRequest != request.id else { return }
            await Task.yield()
            // Owner requirement: prompt jumps never surface anything visible.
            // A miss is a silent no-op by design; the error is intentionally dropped.
            guard !Task.isCancelled, let stream else { return }
            _ = await stream.navigatePrompt(seq: request.seq, historyGeneration: request.generation)
            if !Task.isCancelled { handledPromptRequest = request.id }
        }
        .onDisappear {
            stream?.stop()
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { stream?.stop() }
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

    /// Everything but a failed stream draws into the emulator, including a
    /// stream still attaching (it reports its grid while attaching).
    private func showsEmulator(_ stream: RemoteTerminalStream) -> Bool {
        guard startError == nil, !runsElsewhere, !showsRestartPrompt, !isStarting else { return false }
        if case .failed = stream.phase { return false }
        return true
    }

    @ViewBuilder
    private var status: some View {
        if let startError {
            startFailure(startError)
        } else if runsElsewhere {
            runningElsewhereNote
        } else if showsRestartPrompt {
            restartPrompt
        } else if let stream, !isStarting {
            if case .failed(let error) = stream.phase {
                ContentUnavailableView {
                    Label("terminal.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("action.retry") { stream.retry() }
                }
            } else if (stream.phase == .connecting && (!sawLive || !isReady)) || Self.inspectWaiting {
                waitingIndicator
            }
        } else {
            waitingIndicator
        }
    }

    #if DEBUG
    /// `-CorralInspectTerminalWaiting` keeps the waiting indicator up for captures.
    private static let inspectWaiting = ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalWaiting")
    #else
    private static let inspectWaiting = false
    #endif

    /// Shown before the first frame or during a real host reconnection. A
    /// returning, still-connected terminal keeps its last drawn screen.
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
        // The pane may have closed or switched hosts while the detached task
        // was in flight: never resume a session nobody is watching.
        guard isPresented, isReady else { return }
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
        // Closed mid-resume: allow a later reopen to retry instead of sticking
        // in attempted-but-never-started.
        guard isPresented else {
            startAttempted = false
            return
        }
        stream?.stop()
        stream = nil
        sawLive = false
        if isPresented { startIfNeeded() }
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
            sawLive = false
        }
        if stream == nil {
            stream = RemoteTerminalStream(sessionKey: session.key, client: client)
        }
        if let stream {
            lifetime?.bindTerminal(start: { [weak stream] in stream?.start() },
                                   stop: { [weak stream] in stream?.stop() })
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
