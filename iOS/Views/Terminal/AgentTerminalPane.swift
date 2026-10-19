import SwiftUI

/// One retained native emulator for this detail. Visibility owns the stream,
/// size vote and keyboard. Entering a stopped session resumes it once.
struct AgentTerminalPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    let session: SessionSummary
    let isPresented: Bool
    /// Visible beneath a sheet: the stream stays live but takes no input.
    var inputSuspended = false
    var promptRequest: TerminalPromptRequest? = nil
    /// Reports how a prompt request ended, for the tapped row's status.
    var onPromptOutcome: (UUID, TerminalPromptOutcome) -> Void = { _, _ in }

    @State private var stream: RemoteTerminalStream?
    @State private var isResuming = false
    @State private var startAttempted = false
    @State private var resumed = false
    @State private var resumeError: String?
    @State private var sawScreen = false
    @State private var handledPromptRequest: UUID?
    @State private var visibility = TerminalVisibility()

    var body: some View {
        ZStack {
            if let stream {
                ShellTerminalView(stream: stream, isPresented: isPresented,
                                  allowsInput: isActive && isReady && !isReadonly && !inputSuspended && stream.phase == .live,
                                  isAgent: true)
            }
            if isPresented { status }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .background {
            if isPresented { background }
        }
        .task(id: isActive && isReady && !isReadonly && needsStart) {
            guard isActive, isReady, !isReadonly, needsStart else { return }
            // resume owns an unstructured task: changing startAttempted must
            // not cancel the very request it just started.
            resume()
        }
        .task(id: ConnectionKey(client: appModel.clientIdentity, active: isActive && isReady,
                                hosted: session.hosted || resumed)) {
            updateStream()
        }
        .onChange(of: stream?.phase) { _, phase in
            if phase == .live { sawScreen = true }
        }
        .onChange(of: isPresented) { _, presented in
            visibility.active = presented && scenePhase == .active
            if !presented { stream?.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            visibility.active = isPresented && phase == .active
            if phase != .active { stream?.stop() }
        }
        .task(id: TerminalPromptTaskKey(request: promptRequest?.id, stream: stream.map(ObjectIdentifier.init),
                                         presented: isPresented, ready: stream?.phase == .live)) {
            guard isPresented, let request = promptRequest, handledPromptRequest != request.id else { return }
            await Task.yield()
            // The outcome reaches only the tapped row's status; the terminal
            // itself never shows popups, banners or fallback controls.
            guard !Task.isCancelled, let stream, stream.phase == .live else { return }
            let outcome = await stream.navigatePrompt(seq: request.seq, historyGeneration: request.generation)
            if !Task.isCancelled { handledPromptRequest = request.id }
            onPromptOutcome(request.id, outcome)
        }
        .onDisappear {
            visibility.active = false
            stream?.stop()
        }
    }

    private var isActive: Bool { isPresented && scenePhase == .active }
    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }
    private var isReadonly: Bool { SessionActionsMenu.isReadonly(access: appModel.connectedAccess) }

    /// Match Mac: a stopped session on entry, including a stale first attach,
    /// starts once. Never undo the user's exit after showing a live terminal.
    private var needsStart: Bool {
        guard !startAttempted, !isResuming, resumeError == nil else { return false }
        if let stream { return stream.phase == .ended && !sawScreen }
        return !session.hosted && !session.live && !resumed
    }

    private func updateStream() {
        visibility.active = isActive
        guard isActive, isReady, !isResuming, let client = appModel.client, session.hosted || resumed else {
            stream?.stop()
            return
        }
        if stream?.clientIdentity != ObjectIdentifier(client) {
            stream?.stop()
            let next = RemoteTerminalStream(sessionKey: session.key, client: client)
            let visibility = visibility
            next.isInFront = { visibility.active }
            stream = next
            sawScreen = false
        }
        stream?.start()
    }

    @ViewBuilder
    private var status: some View {
        if let resumeError {
            ContentUnavailableView {
                Label("terminal.start_failed.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: resumeError)
            } actions: {
                Button("action.retry", action: resume).disabled(!isReady || isResuming || isReadonly)
            }
        } else if isResuming {
            ProgressView()
        } else if session.live && !session.hosted && !resumed {
            ContentUnavailableView {
                Label("terminal.running_elsewhere.title", systemImage: "macwindow.on.rectangle")
            } description: {
                Text("terminal.running_elsewhere.description")
            }
        } else if (stream?.phase == .ended || (!session.hosted && !resumed)) && (isReadonly || sawScreen || startAttempted) {
            ContentUnavailableView {
                Label("terminal.not_running.title", systemImage: "terminal")
            } description: {
                Text("terminal.not_running.description")
            } actions: {
                if !isReadonly {
                    Button("session.actions.resume", action: resume)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isReady || isResuming)
                }
            }
        } else if let stream, case .failed(let error) = stream.phase {
            ContentUnavailableView {
                Label("terminal.load_failed.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("action.retry") { stream.retry() }.disabled(!isReady)
            }
        } else if !isReady || !sawScreen {
            ProgressView {
                Text(appModel.connectionState == .reconnecting ? "connection.reconnecting" : "connection.connecting")
            }
            .padding(Space.md)
            .background(.regularMaterial, in: .rect(cornerRadius: Radius.lg))
        }
    }

    private func resume() {
        guard isActive, isReady, !isReadonly, !isResuming, let client = appModel.client else { return }
        startAttempted = true
        isResuming = true
        resumeError = nil
        Task {
            defer {
                isResuming = false
                updateStream()
            }
            do {
                _ = try await client.call(WireProtocol.mSessionResume, params: ["key": session.key])
                guard appModel.client === client else {
                    startAttempted = false
                    return
                }
                resumed = true
                stream?.stop()
                stream = nil
                sawScreen = false
            } catch {
                guard appModel.client === client else {
                    startAttempted = false
                    return
                }
                resumeError = SessionActionsMenu.failureMessage(for: error)
            }
        }
    }

    private var background: Color {
        let rgb = (colorScheme == .dark ? TerminalColorScheme.dark : .light).background
        return Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }

    private final class TerminalVisibility { var active = false }

    private struct ConnectionKey: Hashable {
        let client: ObjectIdentifier?
        let active: Bool
        let hosted: Bool
    }
}
