import SwiftUI

/// One retained native emulator for this detail. Visibility owns the stream,
/// size vote and keyboard; a switch never starts or stops the agent itself.
struct AgentTerminalPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    let session: SessionSummary
    let isPresented: Bool
    var promptRequest: TerminalPromptRequest? = nil
    @State private var promptError: String?

    @State private var stream: RemoteTerminalStream?
    @State private var isResuming = false
    @State private var resumed = false
    @State private var resumeError: String?
    @State private var sawScreen = false
    @State private var visibility = TerminalVisibility()

    var body: some View {
        ZStack {
            if let stream {
                ShellTerminalView(stream: stream, isPresented: isPresented,
                                  allowsInput: isActive && isReady && !isReadonly && stream.phase == .live,
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
        .task(id: ConnectionKey(client: appModel.clientIdentity, active: isActive,
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
        .task(id: promptRequest?.id) {
            guard isPresented, let request = promptRequest else { return }
            await Task.yield()
            guard !Task.isCancelled, let stream else {
                promptError = String(localized: "terminal.prompt.unavailable")
                return
            }
            promptError = await stream.navigatePrompt(seq: request.seq, historyGeneration: request.generation)
        }
        .alert("session.detail.user_prompts", isPresented: Binding(
            get: { promptError != nil }, set: { if !$0 { promptError = nil } }
        )) {
            Button("action.ok", role: .cancel) { promptError = nil }
        } message: {
            Text(verbatim: promptError ?? "")
        }
        .onDisappear {
            visibility.active = false
            stream?.stop()
        }
    }

    private var isActive: Bool { isPresented && scenePhase == .active }
    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }
    private var isReadonly: Bool { SessionActionsMenu.isReadonly(access: appModel.connectedAccess) }

    private func updateStream() {
        visibility.active = isActive
        guard isActive, let client = appModel.client, session.hosted || resumed else {
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
        } else if stream?.phase == .ended || (!session.hosted && !resumed) {
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
        guard isReady, !isReadonly, !isResuming, let client = appModel.client else { return }
        isResuming = true
        resumeError = nil
        Task {
            defer { isResuming = false }
            do {
                _ = try await client.call(WireProtocol.mSessionResume, params: ["key": session.key])
                guard appModel.client === client else { return }
                resumed = true
                stream?.stop()
                stream = nil
                sawScreen = false
                updateStream()
            } catch {
                guard appModel.client === client else { return }
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
