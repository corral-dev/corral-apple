import AppKit
import SwiftUI

/// Main window, modelled on the desktop TUI: session sidebar on the left, the
/// split workspace (up to four panes, a TUI session group) or the Active
/// sessions board on the right. With no paired machine it is the pairing page.
struct MacRootView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(MacInterfaceZoom.self) private var zoom
    #if DEBUG
    @State private var inspectedNewSession = false
    #endif

    @Environment(AppModel.self) private var appModel
    @Environment(MacCommandCenter.self) private var commands

    @State private var notifications = MacNotifications.shared
    @State private var workspace = MacWorkspace()
    @State private var feed: HostSessionFeed?
    @State private var feedConnectionEpoch = 0
    @State private var feedClientIdentity: ObjectIdentifier?
    /// A session created here opens with the composer focused (new-session rule).
    @State private var autoFocusKey: String?
    @State private var newSessionAsPane = false
    @State private var showNewSession = false
    @State private var showPairing = false
    @State private var showSearch = false
    @State private var pairingError: String?
    @State private var clickMonitor: Any?
    @SceneStorage("corral.mac.panesByHost") private var restoredPanesByHost = ""
    /// The host runs project shells and this pairing may use them (terminal panes).
    @State private var shellSupported = false
    @State private var restoringHostID: String?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appModel.hosts.isEmpty {
                MacPairingView()
                    .modifier(MacZoomContent())
            } else {
                splitView
            }
        }
        .environment(workspace)
        .onChange(of: interfaceScale, initial: true) { _, scale in workspace.interfaceScale = scale }
        .sheet(isPresented: $showPairing) {
            MacPairingView(isSheet: true)
                .modifier(MacZoomContent())
                .interfaceFrame(width: 520, height: 460)
        }
        .onOpenURL { url in
            Task { await pair(url: url) }
        }
        .alert(
            "pairing.failed.title",
            isPresented: Binding(get: { pairingError != nil }, set: { if !$0 { pairingError = nil } })
        ) {
            Button("action.ok", role: .cancel) { pairingError = nil }
        } message: {
            Text(verbatim: pairingError ?? "")
        }
        .alert(
            "mac.action.failed",
            isPresented: Binding(get: { workspace.actionError != nil }, set: { if !$0 { workspace.actionError = nil } })
        ) {
            Button("action.ok", role: .cancel) { workspace.actionError = nil }
        } message: {
            Text(verbatim: workspace.actionError ?? "")
        }
        .alert("settings.notifications", isPresented: Binding(
            get: { notifications.failure != nil }, set: { if !$0 { notifications.failure = nil } }
        )) {
            Button("action.ok", role: .cancel) { notifications.failure = nil }
        } message: { Text(verbatim: notifications.failure ?? "") }
        .task(id: notifications.pendingOpen.ticket) {
            if let feed { await notifications.resolvePending(feed: feed, workspace: workspace) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .corralPendingNotificationOpen)) { _ in
            openWindow(id: "main")
            showNewSession = false
            showPairing = false
            showSearch = false
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: commands.pairRequest) { _, _ in showPairing = true }
        .onAppear {
            appModel.refreshHosts()
            workspace.attach(appModel: appModel)
            installClickToFocus()
        }
        .onDisappear(perform: removeClickToFocus)
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-CorralInspectSettings") { openSettings() }
            if arguments.contains("-CorralInspectPairing") { showPairing = true }
        }
        #endif
    }

    private var splitView: some View {
        NavigationSplitView {
            if let feed {
                MacSidebar(
                    feed: feed,
                    onNewSession: { startNewSession(asPane: false) },
                    onPair: { showPairing = true }
                )
                .navigationSplitViewColumnWidth(min: 260 * interfaceScale, ideal: 310 * interfaceScale, max: 440 * interfaceScale)
            } else {
                ProgressView()
                    .navigationSplitViewColumnWidth(min: 260 * interfaceScale, ideal: 310 * interfaceScale, max: 440 * interfaceScale)
            }
        } detail: {
            // Fill the detail column directly. The previous GeometryReader
            // measured the column and then pinned the child to that exact size,
            // forcing a second layout pass over every pane (and every chat row)
            // on each window-resize step. The column already sizes this content.
            detail
                .modifier(MacZoomContent())
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: CGFloat(paneCount) * MacSplitArea.paneMinimum, ideal: 760)
            .toolbar { detailToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .task(id: FeedConnectionKey(hostID: appModel.selectedHost?.hostID, epoch: feedConnectionEpoch)) {
            await runFeed(for: appModel.selectedHost)
        }
        .onChange(of: appModel.connectionState) { _, state in
            if state == .connected {
                if let previous = feedClientIdentity, previous != appModel.clientIdentity {
                    feedClientIdentity = nil
                    feedConnectionEpoch += 1
                } else {
                    workspace.startLayoutWatch()
                }
            }
        }
        .onChange(of: workspace.paneKeys) { _, keys in
            if restoringHostID == nil, let hostID = workspace.hostID { persistPanes(keys, hostID: hostID) }
            if let autoFocusKey, !keys.contains(autoFocusKey) { self.autoFocusKey = nil }
        }
        .onChange(of: needsYouCount, initial: true) { _, count in
            // Dock badge: sessions waiting for an answer on the current machine.
            NSApp.dockTile.badgeLabel = count > 0 ? count.formatted() : nil
        }
        .onChange(of: canCreateSession, initial: true) { _, ready in
            commands.canCreateSession = ready
            commands.hasFocusedPane = workspace.focusedKey != nil
            #if DEBUG
            if ready, !inspectedNewSession,
               ProcessInfo.processInfo.arguments.contains("-CorralInspectNewSession") {
                inspectedNewSession = true
                startNewSession(asPane: false)
            }
            #endif
        }
        .onChange(of: workspace.focusedKey) { _, key in
            commands.hasFocusedPane = key != nil
        }
        .onChange(of: commands.newSessionRequest) { _, _ in startNewSession(asPane: false) }
        .onChange(of: commands.addPaneRequest) { _, _ in startNewSession(asPane: true) }
        .onChange(of: commands.searchRequest) { _, _ in showSearch = true }
        .onChange(of: commands.closePaneRequest) { _, _ in
            if let key = workspace.focusedKey { workspace.requestClose(key) }
        }
        .confirmationDialog(
            "terminal.panel.close_running.title",
            isPresented: Binding(
                get: { workspace.pendingTerminalClose != nil },
                set: { if !$0 { workspace.pendingTerminalClose = nil } }
            ),
            presenting: workspace.pendingTerminalClose
        ) { shell in
            Button("terminal.panel.close_running.confirm", role: .destructive) { workspace.endTerminal(shell.key) }
            Button("action.cancel", role: .cancel) { workspace.pendingTerminalClose = nil }
        } message: { shell in
            Text("terminal.panel.close_running.message \(shell.command)")
        }
        .onChange(of: commands.toggleViewRequest) { _, _ in workspace.toggleModeOfFocusedPane() }
        .onChange(of: commands.toggleTerminalRequest) { _, _ in openTerminal() }
        .onChange(of: commands.newTerminalTabRequest) { _, _ in
            guard canUseTerminal else { return }
            Task { await workspace.newTerminal(project: focusedProject) }
        }
        .onChange(of: appModel.connectionState, initial: true) { _, state in
            guard state == .connected, let client = appModel.client else { return }
            shellSupported = client.hostCapabilities.projectShell
                && !SessionActionsMenu.isReadonly(access: appModel.connectedAccess)
        }
        .onChange(of: canUseTerminal, initial: true) { _, usable in commands.canUseTerminal = usable }
        .onChange(of: appModel.selectedHost?.hostID) { _, _ in shellSupported = false }
        .onChange(of: commands.focusPaneRequest) { _, index in
            if let index { workspace.focusPane(at: index) }
            commands.focusPaneRequest = nil
        }
        .onChange(of: commands.showBoardRequest) { _, _ in workspace.showBoard() }
        .onChange(of: commands.pinRequest) { _, _ in
            if let key = workspace.focusedKey { Task { await workspace.togglePin(key) } }
        }
        .onChange(of: commands.nextAttentionRequest) { _, _ in moveAttention(forward: true) }
        .onChange(of: commands.previousAttentionRequest) { _, _ in moveAttention(forward: false) }
        .sheet(isPresented: $showNewSession) {
            if let host = appModel.selectedHost {
                NewSessionSheet(host: host, preferredProject: focusedProject) { session in
                    autoFocusKey = session.key
                    workspace.openCreated(session, asPane: newSessionAsPane)
                }
                .modifier(MacZoomContent())
            }
        }
        .sheet(isPresented: $showSearch) {
            MacFulltextSearch { key in
                try await workspace.openSearchResult(key)
            }
            .modifier(MacZoomContent())
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let feed, workspace.showingBoard {
            MacActiveBoard(feed: feed)
                .id(feed.host.hostID)
        } else if let feed, !workspace.drawnPaneKeys.isEmpty {
            MacSplitArea(feed: feed, autoFocusKey: autoFocusKey)
                .id(feed.host.hostID)
        } else {
            ContentUnavailableView {
                Label("mac.detail.empty.title", systemImage: "rectangle.split.2x1")
            } actions: {
                Button("sessions.new") { startNewSession(asPane: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreateSession)
            }
            .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        }
    }

    private var paneCount: Int {
        guard workspace.showingBoard, let feed else { return max(workspace.paneKeys.count, 1) }
        let active = DesktopSidebarProjection.activeSessions(feed.listStore.windowSessions)
        let page = min(workspace.boardPage, workspace.boardPages(active: active) - 1)
        return max(1, active.dropFirst(page * MacWorkspace.boardPageSize).prefix(MacWorkspace.boardPageSize).count)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: openTerminal) {
                Label("terminal.panel.title", systemImage: "terminal")
            }
            .help(Text("terminal.panel.toggle.help"))
            .disabled(!canUseTerminal)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showSearch = true
            } label: {
                Label("mac.search.title", systemImage: "text.magnifyingglass")
            }
            .help(Text("mac.search.title"))
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(runtimeChoices, id: \.id) { runtime in
                    Button(runtime.name ?? runtime.id) {
                        Task { await workspace.newSessionPane(runtimeID: runtime.id, project: focusedProject) }
                    }
                }
                if canUseTerminal {
                    Divider()
                    Button("terminal.pane.new") {
                        Task { await workspace.newTerminal(project: focusedProject) }
                    }
                }
                Divider()
                Button("mac.pane.add_other") { startNewSession(asPane: true) }
            } label: {
                Label("mac.pane.add", systemImage: "rectangle.split.2x1")
            }
            .help(Text("mac.pane.add.help"))
            .disabled(!canCreateSession || workspace.paneKeys.isEmpty)
        }
    }

    // MARK: - Derived state

    private var runtimeChoices: [RuntimeEntry] {
        workspace.runtimes.filter { $0.isUsable && $0.isActive }
    }

    private var focusedProject: String {
        guard let key = workspace.focusedKey else { return "" }
        return workspace.projectPath(of: key)
    }

    private var needsYouCount: Int {
        feed?.listStore.windowSessions.filter { SessionPresentation.statusMarker(for: $0) == .waiting }.count ?? 0
    }

    /// Full pairing to a host that runs project shells. Kept through a
    /// reconnect so the panel does not vanish while the connection recovers.
    private var canUseTerminal: Bool { shellSupported }

    private var canCreateSession: Bool {
        guard let host = appModel.selectedHost else { return false }
        return appModel.isConnected(to: host)
            && !SessionActionsMenu.isReadonly(access: appModel.connectedAccess)
    }

    // MARK: - Actions

    /// ⌥F12 / toolbar: the focused project's terminal as a split pane.
    private func openTerminal() {
        guard canUseTerminal else { return }
        Task { await workspace.openTerminal(project: focusedProject) }
    }

    private func startNewSession(asPane: Bool) {
        guard canCreateSession else { return }
        newSessionAsPane = asPane
        showNewSession = true
    }

    /// One feed per selected machine; switching machines tears the old one down
    /// (unwatch on its own client) before the new one subscribes.
    private func runFeed(for host: HostInfo?) async {
        if restoringHostID == nil, let previous = workspace.hostID {
            persistPanes(workspace.paneKeys, hostID: previous)
        }
        restoringHostID = host?.hostID
        feedClientIdentity = nil
        workspace.selectHost(host?.hostID)
        guard let host else {
            notifications.stopFeed()
            feed = nil
            restoringHostID = nil
            return
        }
        let current = await notifications.sessionFeed(host: host, model: appModel)
        feed = current
        workspace.feed = current
        current.onListChanged = { [weak current] in
            if let current { await notifications.resolvePending(feed: current, workspace: workspace) }
        }
        guard !Task.isCancelled, appModel.selectedHost?.hostID == host.hostID,
              feed === current else { return }
        feedClientIdentity = appModel.clientIdentity
        workspace.startLayoutWatch()
        restorePanes(from: current)
        restoringHostID = nil
        await notifications.resolvePending(feed: current, workspace: workspace)
        #if DEBUG
        MacInspection.apply(feed: current, workspace: workspace)
        if MacSessionSwitchInspection.enabled {
            Task { await MacSessionSwitchInspection.run(feed: current, workspace: workspace) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebarSwitches") {
            Task { await MacScrollbarInspection.inspectSidebarIfRequested(feed: current, workspace: workspace) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectZoom") {
            Task { await MacZoomInspection.run(zoom: zoom, workspace: workspace, feed: current, showSettings: { openSettings() }) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectNotifications") {
            Task { await MacNotificationInspection.run(feed: current, workspace: workspace) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectConnectionRecovery") {
            Task { await MacConnectionInspection.run(model: appModel, feed: current) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectLifecycle") {
            Task { await MacLifecycleInspection.run(appModel: appModel, workspace: workspace, feed: current) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectModeSwitch") {
            Task { await MacModeSwitchInspection.run(workspace: workspace, feed: current) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectInteraction") {
            Task { await MacInteractionInspection.run(feed: current, workspace: workspace) }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectSearch") {
            let delay = Double(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SEARCH_DELAY"] ?? "") ?? 0
            if delay.isFinite, delay > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(min(delay, 30)))
                    guard !Task.isCancelled, workspace.feed === current else { return }
                    showSearch = true
                }
            } else {
                showSearch = true
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectProjectTerminal") {
            // A disposable folder keeps acceptance typing out of real shells.
            if let folder = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SHELL_FOLDER"] {
                Task {
                    // Motion acceptance: open after the split settles, then close
                    // again after `CORRAL_INSPECTION_SHELL_CLOSE_AFTER` seconds;
                    // frame pacing of both goes to /tmp/corral-shell-motion.json.
                    let recorder = MotionRecorder()
                    var steps: [[String: Any]] = []
                    for _ in 0..<60 where appModel.connectionState != .connected || !shellSupported {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    try? await Task.sleep(for: .seconds(3))
                    try? "open".write(toFile: "/tmp/corral-shell-motion.txt", atomically: true, encoding: .utf8)
                    let probe = MainThreadStallProbe()
                    recorder.begin(name: "open terminal")
                    probe.begin()
                    await workspace.newTerminal(project: folder)
                    try? await Task.sleep(for: .seconds(MacMotion.seconds(1.2)))
                    steps.append(recorder.end().merging(probe.end()) { $1 })
                    guard let after = Double(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SHELL_CLOSE_AFTER"] ?? ""),
                          let key = workspace.paneKeys.last(where: ProjectShell.isShellKey) else { return }
                    try? await Task.sleep(for: .seconds(after))
                    try? "close".write(toFile: "/tmp/corral-shell-motion.txt", atomically: true, encoding: .utf8)
                    recorder.begin(name: "close terminal")
                    probe.begin()
                    workspace.endTerminal(key)
                    try? await Task.sleep(for: .seconds(MacMotion.seconds(1.2)))
                    steps.append(recorder.end().merging(probe.end()) { $1 })
                    // Baseline: the same add and close with a chat pane.
                    if let compare = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_COMPARE_KEY"],
                       let session = feed?.listStore.session(for: compare) {
                        try? await Task.sleep(for: .seconds(3))
                        recorder.begin(name: "open chat pane")
                        probe.begin()
                        workspace.addPane(compare, project: session.cwd)
                        try? await Task.sleep(for: .seconds(MacMotion.seconds(1.2)))
                        steps.append(recorder.end().merging(probe.end()) { $1 })
                        try? await Task.sleep(for: .seconds(3))
                        recorder.begin(name: "close chat pane")
                        probe.begin()
                        workspace.closePane(compare)
                        try? await Task.sleep(for: .seconds(MacMotion.seconds(1.2)))
                        steps.append(recorder.end().merging(probe.end()) { $1 })
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-shell-motion.json"))
                    }
                }
            } else {
                openTerminal()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectMotion") {
            Task { await MacMotionInspection.run(feed: current, workspace: workspace) }
        }
        #endif
        // The app-owned notification feed keeps watching when this view closes.
    }

    private var savedPanes: [String: [String]] {
        guard let data = restoredPanesByHost.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private func persistPanes(_ keys: [String], hostID: String) {
        var saved = savedPanes
        saved[hostID] = keys
        if let data = try? JSONEncoder().encode(saved) {
            restoredPanesByHost = String(decoding: data, as: UTF8.self)
        }
    }

    private func restorePanes(from feed: HostSessionFeed) {
        guard workspace.paneKeys.isEmpty else { return }
        // Terminal panes come back too; one whose shell ended closes itself.
        let keys = (savedPanes[feed.host.hostID] ?? [])
            .filter { feed.listStore.session(for: $0) != nil || ProjectShell.isShellKey($0) }
        workspace.restorePanes(keys)
    }

    /// ⌥⌘↓ / ⌥⌘↑ walk the sessions waiting for an answer.
    private func moveAttention(forward: Bool) {
        guard let feed else { return }
        let keys = DesktopSidebarProjection.activeSessions(feed.listStore.windowSessions)
            .filter { SessionPresentation.statusMarker(for: $0) == .waiting }
            .map(\.key)
        guard !keys.isEmpty else { return }
        guard let current = workspace.focusedKey, let index = keys.firstIndex(of: current) else {
            workspace.open(forward ? keys[0] : keys[keys.count - 1], sessions: feed.listStore.windowSessions, takeKeys: true)
            return
        }
        let next = (index + (forward ? 1 : -1) + keys.count) % keys.count
        workspace.open(keys[next], sessions: feed.listStore.windowSessions, takeKeys: true)
    }

    /// A click anywhere in a pane focuses it, without intercepting the click
    /// (text selection, buttons and the terminal still receive it).
    private func installClickToFocus() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [workspace] event in
            if let window = event.window, let content = window.contentView {
                let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                if let key = workspace.paneKey(atWindowPoint: point) {
                    workspace.focus(key)
                    // Once the click is handled: keep a text selection or the
                    // pane's composer, else put the caret in the composer.
                    DispatchQueue.main.async { [weak window] in
                        workspace.claimKeysAfterClick(in: key, window: window)
                    }
                }
            }
            return event
        }
    }

    private func removeClickToFocus() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func pair(url: URL) async {
        do {
            let payload = try PairingPayload.parse(url: url)
            _ = try await appModel.completePairing(payload, deviceName: UIDeviceName.current)
        } catch is CancellationError {
            // The window starts its own connection as soon as the paired machine
            // appears; that supersedes the pairing connection, not the pairing.
        } catch {
            pairingError = error.localizedDescription
        }
    }
}

private struct FeedConnectionKey: Hashable {
    let hostID: String?
    let epoch: Int
}

#if DEBUG
/// Debug-only screen inspection, so acceptance captures never drive the pointer:
/// `-CorralInspectConversation` opens the newest session (or
/// `CORRAL_INSPECTION_SESSION_KEY`; several keys separated by commas open a
/// split), `-CorralInspectTerminal` switches the last of them to terminal view,
/// `-CorralInspectBoard` shows the Active sessions board, `-CorralInspectPromptsOpen`
/// opens every pane's prompts card. Release has none.
enum MacInspection {
    static func apply(feed: HostSessionFeed, workspace: MacWorkspace) {
        let arguments = ProcessInfo.processInfo.arguments
        let sessions = feed.listStore.windowSessions
        if arguments.contains("-CorralInspectConversation") {
            let requested = (ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] ?? "")
                .split(separator: ",").map(String.init)
            let keys = requested.isEmpty ? Array(sessions.prefix(1).map(\.key)) : requested
            guard let first = keys.first else { return }
            workspace.open(first, sessions: sessions)
            for key in keys.dropFirst() {
                workspace.addPane(key, project: feed.listStore.session(for: key)?.cwd ?? "")
            }
            if arguments.contains("-CorralInspectTerminal") {
                // The last pane switches to the terminal view; the others stay chat.
                if let last = keys.last { workspace.setMode(.terminal, for: last) }
            }
            workspace.focus(first)
        }
        if arguments.contains("-CorralInspectBoard") {
            workspace.showBoard()
        }
        if arguments.contains("-CorralInspectPromptsOpen") {
            for key in workspace.paneKeys { workspace.promptsOpen[key] = true }
        }
    }
}
#endif
