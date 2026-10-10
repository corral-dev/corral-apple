import SwiftUI

/// Project terminal on iPhone (owner request 2026-10-07): the host's login
/// shells, opened from a session in that session's project folder. Shells keep
/// running on the host after Done; reopening shows the same one. See
/// `docs/design/PROJECT_TERMINAL_DESIGN.md`.
struct ProjectTerminalScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private let project: String

    init(project: String) {
        #if DEBUG
        // Acceptance runs use a disposable folder so typing never reaches a real shell.
        self.project = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SHELL_FOLDER"] ?? project
        #else
        self.project = project
        #endif
    }

    @State private var store = ProjectShellStore()
    @State private var stream: RemoteTerminalStream?
    @State private var pendingClose: ProjectShell?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
                .navigationTitle(Text(verbatim: store.selected?.title ?? projectName))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task(id: LoadKey(client: appModel.clientIdentity, ready: isReady)) { await load() }
        .task(id: StreamKey(shellKey: store.selectedKey, client: appModel.clientIdentity, ready: isReady)) {
            bindStream()
        }
        .onChange(of: stream?.phase) { _, phase in
            if phase == .ended, let key = stream?.sessionKey {
                stream?.stop()
                stream = nil
                store.removeEnded(key)
            }
        }
        .onDisappear {
            stream?.stop()
            stream = nil
        }
        .confirmationDialog(
            "terminal.panel.close_running.title",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            titleVisibility: .visible,
            presenting: pendingClose
        ) { shell in
            Button("terminal.panel.close_running.confirm", role: .destructive) { close(shell.key) }
            Button("action.cancel", role: .cancel) { pendingClose = nil }
        } message: { shell in
            Text("terminal.panel.close_running.message \(shell.command)")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("action.done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: newTab) {
                Label("terminal.panel.new_tab", systemImage: "plus")
            }
            .disabled(store.isWorking || !isReady)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if store.shells.count > 1 {
                    Picker("terminal.panel.tabs", selection: $store.selectedKey) {
                        ForEach(store.shells) { shell in
                            Text(verbatim: shell.title).tag(Optional(shell.key))
                        }
                    }
                    .pickerStyle(.inline)
                }
                if let selected = store.selected {
                    Button(role: .destructive) {
                        Task { await requestClose(selected) }
                    } label: {
                        Label("terminal.panel.close_tab", systemImage: "xmark")
                    }
                }
            } label: {
                Label("terminal.panel.tabs", systemImage: "square.on.square")
            }
            .disabled(store.shells.isEmpty || !isReady)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = store.failure, store.shells.isEmpty {
            ContentUnavailableView {
                Label("terminal.panel.failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: failure)
            } actions: {
                Button("action.retry", action: newTab)
                if !project.isEmpty {
                    Button("terminal.panel.open_home") { newTab(in: "") }
                }
            }
        } else if let stream {
            if case .failed(let error) = stream.phase {
                ContentUnavailableView {
                    Label("terminal.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("action.retry") { stream.retry() }
                }
            } else {
                ShellTerminalView(stream: stream)
                    .id(stream.sessionKey)
                    .overlay {
                        if stream.phase == .connecting { waitingIndicator }
                    }
            }
        } else if store.shells.isEmpty && loaded && !store.isWorking && isReady {
            ContentUnavailableView {
                Label("terminal.panel.empty", systemImage: "terminal")
            } actions: {
                Button("terminal.panel.new_tab", action: newTab)
            }
        } else {
            waitingIndicator
        }
    }

    private var waitingIndicator: some View {
        ProgressView {
            Text(appModel.connectionState == .reconnecting ? "connection.reconnecting" : "connection.connecting")
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.md)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.lg))
    }

    private var background: Color {
        let rgb = (colorScheme == .dark ? TerminalColorScheme.dark : .light).background
        return Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }

    private var projectName: String {
        let name = (project as NSString).lastPathComponent
        return name.isEmpty ? String(localized: "terminal.panel.title") : name
    }

    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }

    /// First appearance selects (or starts) the project's shell; a reconnect
    /// only refreshes the tabs.
    private func load() async {
        guard isReady, let client = appModel.client else { return }
        if loaded {
            await store.refresh(client: client)
            if store.selectedKey == nil { store.selectedKey = store.shells.last?.key }
        } else {
            await store.show(project: project, client: client)
            loaded = true
        }
    }

    private func newTab() { newTab(in: project) }

    /// An empty folder opens the shell in the host's home folder.
    private func newTab(in folder: String) {
        guard isReady, let client = appModel.client else { return }
        Task { await store.open(project: folder, client: client) }
    }

    private func bindStream() {
        guard isReady, let client = appModel.client, let key = store.selectedKey else {
            if store.selectedKey == nil {
                stream?.stop()
                stream = nil
            }
            return
        }
        if let stream, stream.sessionKey == key, stream.clientIdentity == ObjectIdentifier(client) { return }
        stream?.stop()
        let next = RemoteTerminalStream(sessionKey: key, client: client)
        stream = next
        next.start()
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SHELL_TYPE"], !text.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(3))
                next.input.send(ArraySlice(Array((text + "\r").utf8)))
            }
        }
        #endif
    }

    private func requestClose(_ shell: ProjectShell) async {
        guard let client = appModel.client else { return }
        if await store.isBusy(shell.key, client: client) {
            pendingClose = store.shells.first { $0.key == shell.key } ?? shell
        } else {
            close(shell.key)
        }
    }

    private func close(_ key: String) {
        pendingClose = nil
        guard let client = appModel.client else { return }
        if stream?.sessionKey == key {
            stream?.stop()
            stream = nil
        }
        Task { await store.close(key, client: client) }
    }
}

private struct LoadKey: Hashable {
    let client: ObjectIdentifier?
    let ready: Bool
}

private struct StreamKey: Hashable {
    let shellKey: String?
    let client: ObjectIdentifier?
    let ready: Bool
}
