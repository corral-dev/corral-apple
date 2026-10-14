import SwiftUI

/// A project terminal as a split pane (owner decision 2026-10-07): the host
/// login shell `shellKey`, beside the session panes with the same header
/// language, focus rule and close. See `docs/design/PROJECT_TERMINAL_DESIGN.md`.
struct MacShellPane: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.macVisiblePaneKeys) private var visiblePaneKeys
    let shellKey: String

    @State private var stream: RemoteTerminalStream?
    /// The folder name stays in the header while a closed pane fades out
    /// (the store drops the shell as soon as the host ends it).
    @State private var title: String?
    /// The waiting indicator appears only when attaching takes noticeably long,
    /// so an ordinary open shows the terminal background, then the prompt.
    @State private var showsWaiting = false

    private var isFocused: Bool { workspace.focusedKey == shellKey }
    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }
    private var shell: ProjectShell? { workspace.shells.shell(for: shellKey) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: TerminalAppearance.background))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            workspace.paneFrames[shellKey] = frame
        }
        .task(id: PaneConnectionKey(sessionKey: shellKey, client: appModel.clientIdentity, ready: isReady)) {
            await start()
        }
        .onChange(of: shell?.name, initial: true) { _, name in
            if let name { title = name }
        }
        .task(id: isWaiting) {
            showsWaiting = false
            guard isWaiting else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { showsWaiting = true }
        }
        .onChange(of: stream?.phase) { _, phase in
            // `exit` in the shell (or a close elsewhere) ends the stream: the pane goes too.
            if phase == .ended { workspace.terminalEnded(shellKey) }
        }
        .onDisappear {
            workspace.paneFrames[shellKey] = nil
            stream?.stop()
            stream = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm * interfaceScale) {
            Image(systemName: "terminal")
                .interfaceFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 6 * interfaceScale) {
                Text(verbatim: shell?.name ?? title ?? String(localized: "terminal.panel.title"))
                    .interfaceFont(.callout.weight(.semibold))
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let shell, shell.busy, !shell.command.isEmpty {
                    Text(verbatim: shell.command)
                        .interfaceFont(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .interfaceFrame(minWidth: 30, maxWidth: .infinity, alignment: .leading)
            .help(Text(verbatim: shell?.cwd ?? ""))
            Button {
                workspace.requestClose(shellKey)
            } label: {
                Image(systemName: "xmark")
                    .interfaceFont(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.secondary)
            .help(Text("terminal.pane.close"))
            .accessibilityLabel(Text("terminal.pane.close"))
        }
        .interfaceControlSize(.small)
        .interfacePadding(.horizontal, Space.md)
        .interfacePadding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if isFocused && visiblePaneKeys.count > 1 {
                Rectangle()
                    .fill(Palette.accent)
                    .interfaceFrame(height: 2)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(MacMotion.state, value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focus(shellKey)
            workspace.requestKeyFocus(shellKey)
        }
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let stream {
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
                TerminalEmulator(stream: stream, isFocusedPane: isFocused, isPresented: true)
                    .overlay {
                        if showsWaiting { waitingIndicator.transition(.opacity) }
                    }
                    .animation(MacMotion.state, value: showsWaiting)
            }
        } else if showsWaiting {
            waitingIndicator
        }
    }

    private var isWaiting: Bool { stream == nil || stream?.phase == .connecting }

    private var waitingIndicator: some View {
        ProgressView {
            Text(appModel.connectionState == .reconnecting ? "connection.reconnecting" : "connection.connecting")
        }
        .interfaceControlSize(.small)
        .interfacePadding(.horizontal, Space.base)
        .interfacePadding(.vertical, Space.md)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.lg * interfaceScale))
    }

    /// Attaches on a ready connection (again after the client is replaced).
    /// A restored pane whose shell no longer exists on the host closes itself.
    private func start() async {
        guard isReady, let client = appModel.client else { return }
        if await workspace.shells.refresh(client: client), workspace.shells.shell(for: shellKey) == nil {
            workspace.terminalEnded(shellKey)
            return
        }
        if let stream, stream.clientIdentity == ObjectIdentifier(client) { return }
        stream?.stop()
        let next = RemoteTerminalStream(sessionKey: shellKey, client: client)
        stream = next
        next.start()
        #if DEBUG
        inspectTypingIfRequested(next)
        #endif
    }

    #if DEBUG
    /// Debug-only: `CORRAL_INSPECTION_SHELL_TYPE` is typed into the shell
    /// through the same sender as keystrokes, followed by Return, so an
    /// acceptance capture shows a real command and its output.
    private func inspectTypingIfRequested(_ stream: RemoteTerminalStream) {
        guard let text = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SHELL_TYPE"], !text.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            for command in text.components(separatedBy: " ;; ") {
                stream.input.send(ArraySlice(Array((command + "\r").utf8)))
                try? await Task.sleep(for: .seconds(2))
            }
            try? await Task.sleep(for: .seconds(2))
            // `CORRAL_INSPECTION_SHELL_SCROLL_CLEAR`: scroll back a few lines,
            // then type `clear` as key events, as a person would.
            if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SHELL_SCROLL_CLEAR"] != nil {
                TerminalHostView.inspectionLatest?.inspectionScrollUp(lines: 3)
                try? await Task.sleep(for: .seconds(1))
                TerminalHostView.inspectionLatest?.inspectionPressKeys(["c", "l", "e", "a", "r", "\r"])
                try? await Task.sleep(for: .seconds(2))
                debugTrace("shell scroll position after clear: \(TerminalHostView.inspectionLatest?.inspectionScrollPosition ?? -1)")
            }
            let lines = TerminalHostView.inspectionLatest?.inspectionVisibleText ?? []
            debugTrace("shell visible rows:\n" + lines.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"))
        }
    }
    #endif
}
