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
    let isPresented: Bool
    var promptRequest: TerminalPromptRequest? = nil
    /// The prompts card's last row: return the terminal viewport to live output.
    var latestRequest: Int = 0
    /// Reports how a prompt request ended, for the clicked row's status.
    var onPromptOutcome: (UUID, TerminalPromptOutcome) -> Void = { _, _ in }

    @State private var isStarting = false
    @State private var startAttempted = false
    @State private var startTask: Task<Void, Never>?
    @State private var handledPromptRequest: UUID?

    /// The window's long-lived terminal for this session, if one is open
    /// (see `MacTerminalSessions`): returning to it draws its current screen.
    private var terminal: MacTerminalSessions.Terminal? {
        workspace.terminals.terminal(for: session.key, client: appModel.client)
    }
    private var stream: RemoteTerminalStream? { terminal?.stream }
    private var sawLive: Bool { stream?.hasBeenLive ?? false }
    /// The emulator already shows a screen (possibly from an earlier stream).
    private var hasScreen: Bool { sawLive || terminal?.view.hasScreen == true }

    var body: some View {
        // The emulator keeps one structural position for its whole life and
        // hides natively while chat or another session is shown; SwiftUI
        // chrome is drawn only while presented, so nothing covers the chat.
        ZStack {
            if let terminal, showsEmulator(terminal.stream) {
                // Clicks focus the pane through the window's click monitor (MacRootView).
                TerminalEmulator(host: terminal.view, isFocusedPane: isFocused,
                                 isPresented: isPresented,
                                 usesIdentityBackground: SessionPresentation.titleIcon(in: session.title) != nil)
                    .chatReadableColumn()
            }
            if isPresented { status }
        }
        .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isPresented { SessionIdentityBackground(title: session.title) }
        }
        .background {
            if isPresented { Color(nsColor: TerminalAppearance.background) }
        }
        .task(id: isPresented && isReady && needsStart) {
            guard isPresented, isReady, needsStart else { return }
            triggerStart()
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { cancelStart() }
        }
        .onChange(of: isReady) { _, ready in
            if !ready { cancelStart() }
        }
        .onChange(of: session.key) { _, _ in
            cancelStart()
            startAttempted = false
        }
        .onDisappear { cancelStart() }
        .task(id: PaneConnectionKey(sessionKey: session.key, client: appModel.clientIdentity, ready: isPresented && isReady && session.hosted)) {
            guard isPresented, isReady, session.hosted else { return }
            openTerminal()
            #if DEBUG
            if let stream {
                MacTerminalReturnInspection.runIfRequested(
                    workspace: workspace, session: session, stream: stream)
                MacTerminalRecoveryInspection.runIfRequested(stream: stream, client: appModel.client)
            }
            await inspectAppearanceFlipIfRequested()
            await inspectTypingIfRequested()
            #endif
        }
        .task(id: TerminalPromptTaskKey(request: promptRequest?.id, stream: stream.map(ObjectIdentifier.init),
                                         presented: isPresented, ready: stream?.phase == .live)) {
            guard isPresented, let request = promptRequest, handledPromptRequest != request.id else { return }
            await Task.yield()
            // The outcome reaches only the clicked row's status; the terminal
            // itself never shows popups, banners or fallback controls.
            guard !Task.isCancelled, let stream, stream.phase == .live else { return }
            let outcome = await stream.navigatePrompt(seq: request.seq, historyGeneration: request.generation,
                                                      text: request.text)
            if !Task.isCancelled { handledPromptRequest = request.id }
            onPromptOutcome(request.id, outcome)
        }
        .onChange(of: latestRequest) { _, _ in
            // Chat is untouched; only a presented terminal has live output to
            // return to (owner requirement 2026-10-25).
            guard isPresented, let terminal, showsEmulator(terminal.stream) else { return }
            handledPromptRequest = promptRequest?.id
            terminal.stream.cancelPromptNavigation()
            terminal.view.scrollToLiveOutput()
            Task { @MainActor in
                guard await terminal.stream.returnToLatest() else { return }
                terminal.view.scrollToLiveOutput()
            }
        }
    }

    private var isReadonly: Bool { SessionActionsMenu.isReadonly(access: appModel.connectedAccess) }

    /// Opening the view starts a session that is not running, once. A stream
    /// that ends before it ever went live is the same opening (stale summary).
    private var needsStart: Bool {
        guard !startAttempted, !isStarting, !isReadonly else { return false }
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

    /// Everything but a stopped/external pane draws into the emulator, including
    /// a stream still attaching (it reports its grid while attaching).
    private func showsEmulator(_ stream: RemoteTerminalStream) -> Bool {
        !runsElsewhere && !showsRestartPrompt && !isStarting
    }

    @ViewBuilder
    private var status: some View {
        if runsElsewhere {
            runningElsewhereNote
        } else if isReadonly && !session.hosted && !session.live && stream == nil {
            notRunningReadonlyNote
        } else if showsRestartPrompt {
            restartPrompt
        } else if let stream, !isStarting {
            if (stream.phase == .connecting && (!hasScreen || !isReady)) || Self.inspectWaiting {
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

    /// Shown before the first screen or during a real host reconnection. A
    /// returning, still-connected terminal keeps its current screen.
    private var waitingIndicator: some View {
        ProgressView {
            Text(appModel.connectionState == .reconnecting ? "connection.reconnecting" : "connection.connecting")
        }
        .interfaceControlSize(.small)
        .interfacePadding(.horizontal, Space.base)
        .interfacePadding(.vertical, Space.md)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.lg * interfaceScale))
    }

    private var notRunningReadonlyNote: some View {
        ContentUnavailableView {
            Label("terminal.not_running.title", systemImage: "terminal")
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
            Button("terminal.restart") { triggerStart(force: true) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isStarting || isReadonly)
        }
        .interfacePadding(Space.xxl)
    }

    private func triggerStart(force: Bool = false) {
        guard !isStarting, !isReadonly, isPresented, isReady else { return }
        if force { startAttempted = false }
        guard force || needsStart else { return }
        startTask?.cancel()
        let key = session.key
        let clientID = appModel.clientIdentity
        // Detached from the SwiftUI `.task` identity because flipping
        // `startAttempted = true` flips `needsStart` to false.
        startTask = Task { @MainActor in
            defer { startTask = nil }
            await start(key: key, clientID: clientID, force: force)
        }
    }

    private func cancelStart() {
        startTask?.cancel()
        startTask = nil
    }

    private func start(key: String, clientID: ObjectIdentifier?, force: Bool) async {
        guard !isStarting, !isReadonly, isPresented, isReady,
              session.key == key, appModel.clientIdentity == clientID else { return }
        startAttempted = true
        isStarting = true
        defer { isStarting = false }
        var attempt = 0
        while !Task.isCancelled, isPresented, isReady, !isReadonly,
              session.key == key, appModel.clientIdentity == clientID {
            if !force && ((session.hosted && stream?.phase != .ended) || session.live) {
                if session.hosted, let client = appModel.client {
                    workspace.terminals.open(session.key, client: client)
                }
                return
            }
            if let error = await workspace.resumeInPane(session.key) {
                #if DEBUG
                debugTrace("terminal start attempt \(attempt + 1) failed: \(error)")
                #endif
                guard !Task.isCancelled, isPresented, isReady, !isReadonly,
                      session.key == key, appModel.clientIdentity == clientID else {
                    startAttempted = false
                    return
                }
                switch RemoteRecoveryPolicy.classify(error) {
                case .retryable:
                    let delay = RemoteRecoveryPolicy.backoffDuration(attempt: attempt)
                    attempt += 1
                    try? await Task.sleep(for: delay)
                    continue
                case .notFound, .permanent:
                    startAttempted = false
                    return
                }
            }
            // Closed mid-resume: allow a later reopen to start cleanly instead
            // of sticking in attempted-but-never-started.
            guard isPresented, isReady, session.key == key, appModel.clientIdentity == clientID else {
                startAttempted = false
                return
            }
            if let client = appModel.client { workspace.terminals.restart(session.key, client: client) }
            #if DEBUG
            debugTrace("terminal started session; phase=\(String(describing: stream?.phase))")
            #endif
            return
        }
        startAttempted = false
    }

    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }

    /// Opens (or marks as shown) this session's long-lived terminal.
    private func openTerminal() {
        guard let client = appModel.client else { return }
        workspace.terminals.open(session.key, client: client)
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
