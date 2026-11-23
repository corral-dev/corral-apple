import SwiftUI

/// Agent terminal pane backed by `MobileTerminalSessions` so opened terminals
/// outlive transient detail mounts (Back navigation, session switches, Chat
/// toggles, and `NavigationSplitView` relocation) and reveal immediately on return.
struct AgentTerminalPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MobileTerminalSessions.self) private var terminals
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    let session: SessionSummary
    let isPresented: Bool
    /// Visible beneath a sheet: the stream stays live but takes no input.
    var inputSuspended = false
    var promptRequest: TerminalPromptRequest? = nil
    /// Reports how a prompt request ended, for the tapped row's status.
    var onPromptOutcome: (UUID, TerminalPromptOutcome) -> Void = { _, _ in }
    var onBackgroundColorChange: (TerminalRGB?) -> Void = { _ in }

    @State private var sampledBackground: TerminalRGB?
    @State private var isResuming = false
    @State private var startAttempted = false
    @State private var resumed = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var handledPromptRequest: UUID?

    private var terminal: MobileTerminalSessions.Terminal? {
        terminals.terminal(for: session.key, client: appModel.client)
    }

    private var stream: RemoteTerminalStream? { terminal?.stream }
    private var sawLive: Bool { stream?.hasBeenLive ?? false }
    private var hasScreen: Bool { sawLive || terminal?.view.hasScreen == true }

    var body: some View {
        ZStack {
            if let terminal, showsEmulator {
                RetainedShellTerminalView(
                    host: terminal.view,
                    isPresented: isPresented,
                    sceneActive: scenePhase == .active,
                    allowsInput: isActive && isReady && !isReadonly && !inputSuspended && terminal.stream.phase == .live,
                    isAgent: true,
                    usesIdentityBackground: SessionPresentation.titleIcon(in: session.title) != nil,
                    fontSize: CGFloat(appModel.mobileTerminalFontSize),
                    onFontSizeChange: { appModel.mobileTerminalFontSize = $0 },
                    onBackgroundColorChange: { rgb in
                        terminal.sampledBackground = rgb
                        sampledBackground = rgb
                        onBackgroundColorChange(rgb)
                    }
                )
            }
            if isPresented { status }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .background {
            if isPresented { SessionIdentityBackground(title: session.title) }
        }
        .background {
            if isPresented { background }
        }
        .onAppear {
            syncCachedBackground()
        }
        .onChange(of: terminal?.sampledBackground, initial: true) { _, _ in
            syncCachedBackground()
        }
        .task(id: isActive && isReady && !isReadonly && needsStart) {
            guard isActive, isReady, !isReadonly, needsStart else { return }
            // resume owns an unstructured task: changing startAttempted must
            // not cancel the very request it just started.
            resume()
        }
        .task(id: ConnectionKey(client: appModel.clientIdentity, active: isActive && isReady,
                                hosted: session.hosted || resumed)) {
            openTerminal()
        }
        .onChange(of: session.hosted) { _, hosted in
            if hosted, isActive, isReady, !isResuming, stream?.phase == .ended, let client = appModel.client {
                terminals.restart(session.key, client: client)
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                cancelResume()
            } else {
                syncCachedBackground()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelResume() }
        }
        .onChange(of: isReady) { _, ready in
            if !ready { cancelResume() }
        }
        .onChange(of: colorScheme) { _, _ in
            if stream == nil {
                sampledBackground = nil
                onBackgroundColorChange(nil)
            }
        }
        .task(id: TerminalPromptTaskKey(request: promptRequest?.id, stream: stream.map(ObjectIdentifier.init),
                                         presented: isPresented, ready: stream?.phase == .live)) {
            guard isPresented, let request = promptRequest, handledPromptRequest != request.id else { return }
            await Task.yield()
            // The outcome reaches only the tapped row's status; the terminal
            // itself never shows popups, banners or fallback controls.
            guard !Task.isCancelled, let stream, stream.phase == .live else { return }
            let outcome = await stream.navigatePrompt(seq: request.seq, historyGeneration: request.generation,
                                                      text: request.text)
            if !Task.isCancelled { handledPromptRequest = request.id }
            onPromptOutcome(request.id, outcome)
        }
        .onDisappear {
            cancelResume()
        }
    }

    private var isActive: Bool { isPresented && scenePhase == .active }
    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }
    private var isReadonly: Bool { SessionActionsMenu.isReadonly(access: appModel.connectedAccess) }

    /// Match Mac: a stopped session on entry, including a stale first attach,
    /// starts once. Never undo the user's exit after showing a live terminal.
    private var needsStart: Bool {
        guard !startAttempted, !isResuming else { return false }
        if let stream { return stream.phase == .ended && !sawLive }
        return !session.hosted && !session.live && !resumed
    }

    private var runsElsewhere: Bool {
        stream == nil && !isResuming && session.live && !session.hosted && !resumed
    }

    private var showsRestartPrompt: Bool {
        guard !isResuming else { return false }
        if let stream, stream.phase == .ended {
            return isReadonly || sawLive || startAttempted
        }
        return !session.hosted && !resumed && !session.live && (isReadonly || startAttempted)
    }

    private var showsEmulator: Bool {
        !runsElsewhere && !showsRestartPrompt && !isResuming
    }

    private func openTerminal() {
        guard isActive, isReady, !isResuming, let client = appModel.client, session.hosted || resumed else { return }
        terminals.open(session.key, client: client, fontSize: CGFloat(appModel.mobileTerminalFontSize))
    }

    private func syncCachedBackground() {
        guard let rgb = terminal?.sampledBackground ?? terminal?.view.currentBackgroundRGB else { return }
        if sampledBackground != rgb {
            sampledBackground = rgb
        }
        if isPresented {
            onBackgroundColorChange(rgb)
        }
    }

    @ViewBuilder
    private var status: some View {
        if isResuming {
            waitingIndicator
        } else if runsElsewhere {
            ContentUnavailableView {
                Label("terminal.running_elsewhere.title", systemImage: "macwindow.on.rectangle")
            } description: {
                Text("terminal.running_elsewhere.description")
            }
        } else if showsRestartPrompt {
            ContentUnavailableView {
                Label("terminal.not_running.title", systemImage: "terminal")
            } description: {
                if !isReadonly {
                    Text("terminal.not_running.description")
                }
            } actions: {
                if !isReadonly {
                    Button("session.actions.resume") { resume(force: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isReady || isResuming)
                }
            }
        } else if let stream {
            if stream.phase == .connecting && (!hasScreen || !isReady) {
                waitingIndicator
            }
        } else {
            waitingIndicator
        }
    }

    private var waitingIndicator: some View {
        ProgressView {
            Text(appModel.connectionState == .reconnecting ? "connection.reconnecting" : "connection.connecting")
        }
        .padding(Space.md)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.lg))
    }

    private func cancelResume() {
        resumeTask?.cancel()
        resumeTask = nil
    }

    private func resume(force: Bool = false) {
        guard isActive, isReady, !isReadonly, !isResuming, let client = appModel.client else { return }
        if force { startAttempted = false }
        startAttempted = true
        isResuming = true
        resumeTask?.cancel()
        resumeTask = Task {
            defer {
                isResuming = false
                resumeTask = nil
                openTerminal()
            }
            var attempt = 0
            while !Task.isCancelled, isActive, isReady, !isReadonly, appModel.client === client {
                if !force && ((session.hosted && stream?.phase != .ended) || resumed) {
                    return
                }
                do {
                    _ = try await client.call(WireProtocol.mSessionResume, params: ["key": session.key])
                    guard !Task.isCancelled, isActive, isReady, appModel.client === client else {
                        startAttempted = false
                        return
                    }
                    resumed = true
                    terminals.restart(session.key, client: client)
                    return
                } catch {
                    guard !Task.isCancelled, isActive, isReady, !isReadonly, appModel.client === client else {
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
            }
            startAttempted = false
        }
    }

    private var background: Color {
        (sampledBackground ?? terminal?.sampledBackground ?? TerminalColorScheme.forAppearance(isDark: colorScheme == .dark).backgroundRGB).swiftUIColor
    }

    private struct ConnectionKey: Hashable {
        let client: ObjectIdentifier?
        let active: Bool
        let hosted: Bool
    }
}
