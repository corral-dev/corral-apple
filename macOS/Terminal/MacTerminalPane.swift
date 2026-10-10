import SwiftUI

/// Terminal view of one pane: the agent's own TUI, live from the host.
/// A session without a hosted pane offers Return to restart it natively, the
/// same action as Return on the TUI's ended-session preview.
struct MacTerminalPane: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    let session: SessionSummary
    let isFocused: Bool

    @State private var stream: RemoteTerminalStream?
    @State private var isRestarting = false

    var body: some View {
        Group {
            if showsRestartPrompt {
                restartPrompt
            } else if let stream {
                content(stream)
            } else {
                waitingIndicator
            }
        }
        .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: TerminalAppearance.background))
        #if DEBUG
        .task(id: isReady) { await inspectRestartIfRequested() }
        #endif
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

    private var showsRestartPrompt: Bool {
        guard !isRestarting else { return false }
        // The action response and list broadcast can arrive in either order.
        // Keep the emulator mounted while attaching so it can report its grid;
        // a stale unhosted summary must not hide connection errors either.
        if let stream { return stream.phase == .ended }
        return !session.hosted
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
            Button("terminal.restart") { Task { await restart() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRestarting)
        }
        .interfacePadding(Space.xxl)
    }

    private func restart() async {
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        if await workspace.resume(session.key) {
            stream?.stop()
            stream = nil
            startIfNeeded()
        }
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
    /// Calls the button's action on a disposable session without driving the pointer.
    private func inspectRestartIfRequested() async {
        guard isReady, ProcessInfo.processInfo.arguments.contains("-CorralInspectTerminalRestart"),
              session.cwd.hasPrefix("/private/tmp/corral-restart-acceptance") else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, showsRestartPrompt else { return }
        await restart()
        debugTrace("terminal restart inspection completed; phase=\(String(describing: stream?.phase))")
    }

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
