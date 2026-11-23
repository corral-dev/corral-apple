#if os(iOS)
import SwiftUI

/// The one adaptive iOS container (owner decisions 2026-11-01): a regular
/// width (iPad, unfolded iPhone Duo) shows a Mac-like sidebar of the selected
/// machine's sessions beside the selected conversation; a compact width
/// (iPhone, folded Duo, narrow windows) collapses it natively to a stack.
/// Folding is a resize of this same tree, so the open conversation, draft,
/// scroll position and chat/terminal mode carry over. Never chosen by idiom.
/// Without a paired machine it is the machines page with its pairing state.
struct SessionSplitRoot: View {
    @Environment(AppModel.self) private var appModel
    @State private var showPairing = false

    var body: some View {
        Group {
            if let host = appModel.selectedHost {
                SessionSplitView(host: host, onPair: { showPairing = true })
                    // A machine switch starts a fresh feed and clears the selection.
                    .id(host.hostID)
            } else {
                NavigationStack { HostListView() }
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingScannerView()
        }
        .focusedSceneValue(\.corralPairMachine, CorralCommandAction(id: "pair") { showPairing = true })
        .onAppear {
            appModel.refreshHosts()
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectPairing") {
                showPairing = true
            }
        }
    }
}

private struct SessionSplitView: View {
    let host: HostInfo
    let onPair: () -> Void

    /// The window's width class, read outside the columns (a sidebar column
    /// always reports compact). Compact means the split shows one stack.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppModel.self) private var appModel
    @State private var feed: HostSessionFeed
    @State private var presentation = ConversationPresentation()
    @State private var terminals = MobileTerminalSessions()
    @State private var selection: SessionRoute?
    /// A conversation opened by New Session (or copy/hand-off) focuses its composer once.
    @State private var autoFocusKey: String?
    @State private var modeRequestCounter = 0
    @State private var requestedMode: SessionModeRequest?
    @State private var showSettings = false
    @State private var newSessionRequest = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let modeStore = SessionDetailModeStore.shared

    init(host: HostInfo, onPair: @escaping () -> Void) {
        self.host = host
        self.onPair = onPair
        _feed = State(initialValue: HostSessionFeed(host: host))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionListView(
                host: host,
                feed: feed,
                split: SessionSplitContext(
                    selection: Binding(
                        get: { selection },
                        set: { select($0, focusComposer: false) }
                    ),
                    open: { select($0, focusComposer: $1) },
                    openMode: { select($0, focusComposer: false, initialMode: $1) },
                    showSettings: { showSettings = true },
                    showPairing: onPair,
                    newSessionRequest: newSessionRequest,
                    isCollapsed: horizontalSizeClass != .regular
                )
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            .modifier(HorizontalBars())
        } detail: {
            NavigationStack { detail.modifier(HorizontalBars()) }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(terminals)
        .onChange(of: appModel.clientIdentity) { _, _ in
            prepareSelectedConversation()
        }
        .onAppear { prepareSelectedConversation() }
        .onDisappear {
            presentation.dismiss()
            terminals.reset()
            modeStore.discardEmptyEntries()
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectNotifications") {
                showSettings = true
            }
        }
        #endif
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                HostSettingsView(host: host)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("action.done") { showSettings = false }
                        }
                    }
            }
        }
    }

    private func select(_ route: SessionRoute?, focusComposer: Bool, initialMode: SessionDetailMode? = nil) {
        autoFocusKey = focusComposer ? route?.key : nil
        if let initialMode, let route {
            recordMode(initialMode, for: route.key)
            modeRequestCounter &+= 1
            requestedMode = SessionModeRequest(id: modeRequestCounter, mode: initialMode)
        } else if selection?.key != route?.key {
            requestedMode = nil
        }
        selection = route
        prepareSelectedConversation()
    }

    private func canonicalSessionKey(for key: String) -> String {
        feed.listStore.resolvedKey(key)
    }

    private func rememberedMode(for sessionKey: String) -> SessionDetailMode {
        modeStore.effectiveMode(for: canonicalSessionKey(for: sessionKey), hostID: host.hostID)
    }

    private func recordMode(_ mode: SessionDetailMode, for sessionKey: String) {
        modeStore.setMode(mode, for: canonicalSessionKey(for: sessionKey), hostID: host.hostID)
    }

    private func prepareSelectedConversation() {
        guard let route = selection,
              let session = feed.listStore.session(for: route.key) else {
            presentation.dismiss()
            return
        }
        let store = presentation.present(
            sessionKey: session.key, hostID: host.hostID, client: appModel.client,
            live: session.live, attention: session.attention
        )
        let listStore = feed.listStore
        store.onSessionMetadata = { summary, revision in
            listStore.applySessionEvent(summary, revision: revision)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let route = selection, let session = feed.listStore.session(for: route.key),
           let store = presentation.store {
            SessionDetailView(
                session: session,
                autoFocusComposer: autoFocusKey == route.key,
                initialMode: rememberedMode(for: session.key),
                modeRequest: requestedMode,
                onModeChange: { mode in
                    requestedMode = nil
                    recordMode(mode, for: session.key)
                },
                metadataStore: feed.listStore,
                injectedStore: store,
                onDidCreateSession: { created in
                    feed.listStore.patchSession(created)
                    feed.listStore.rememberOpened(created)
                    select(SessionRoute(key: created.key), focusComposer: true)
                },
                onPin: { Task { try? await feed.togglePin(session) } },
                onStop: { _ = try await feed.stop(session) },
                onDelete: { target in
                    Task {
                        do {
                            let canonicalKey = canonicalSessionKey(for: target.key)
                            try await feed.delete(target)
                            terminals.close(target.key)
                            if canonicalKey != target.key {
                                terminals.close(canonicalKey)
                            }
                            if selection?.key == target.key {
                                selection = nil
                                presentation.dismiss()
                            }
                        } catch {
                            // Error is surfaced by feed.loadError.
                        }
                    }
                }
            )
            // A replaced client owns a different store even for the same key.
            // Rebuild the detail's local @State binding, not the selected route.
            .id(ObjectIdentifier(store))
            .onAppear {
                feed.listStore.revealSession(session)
                feed.listStore.markReadLocally(key: session.key)
                Task { await store.markRead() }
            }
        } else {
            ContentUnavailableView {
                Label("mac.detail.empty.title", systemImage: "bubble.left.and.bubble.right")
            } actions: {
                Button("sessions.new") { newSessionRequest += 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .foregroundStyle(Palette.onAccent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        }
    }
}

/// Every screen keeps horizontal bars (owner reports 2026-11-01). On the iPhone
/// Duo outer display the iOS 27.1 vertical bar spans the status column, so the
/// conversation's composer was short and Send sat out of a right thumb's
/// reach. Opting out on the conversation alone made a push from the list (rail)
/// animate through a broken state: "⋯" parked under the composer and no Back.
/// One axis everywhere also keeps controls in one place across screens.
/// Apple's documented opt-out case covers bottom-heavy screens.
private struct HorizontalBars: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
    }
}

/// The session list title, as on the Mac sidebar's machine switcher: the
/// current machine and its connection route, opening every paired machine
/// (check mark on the current one) and pairing.
struct SessionMachineSwitcher: View {
    @Environment(AppModel.self) private var appModel
    let host: HostInfo
    let onPair: () -> Void

    var body: some View {
        Menu {
            ForEach(appModel.hosts) { candidate in
                Button {
                    appModel.selectHost(candidate)
                } label: {
                    if candidate.hostID == host.hostID {
                        Label(candidate.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: candidate.displayName)
                    }
                }
            }
            Divider()
            Button(action: onPair) {
                Label("mac.pair_machine", systemImage: "qrcode.viewfinder")
            }
        } label: {
            SessionPrincipalHeader(
                deviceName: host.displayName,
                state: appModel.connectionState,
                transport: appModel.activeTransport
            )
        }
        .accessibilityLabel(Text("mac.machine_switcher"))
    }
}

/// Menu bar and hardware-keyboard commands (iPadOS menu bar, ⌘-hold overlay).
/// Shortcuts match the Mac where the action exists; each command dims when
/// the focused scene offers no action, and every action stays reachable by touch.
struct CorralIOSCommands: Commands {
    @FocusedValue(\.corralNewSession) private var newSession
    @FocusedValue(\.corralPairMachine) private var pairMachine
    @FocusedValue(\.corralSearchSessions) private var searchSessions
    @FocusedValue(\.corralToggleSessionMode) private var toggleSessionMode
    @FocusedValue(\.corralFocusedSessionMode) private var focusedSessionMode

    private var toggleViewTitle: LocalizedStringKey {
        switch focusedSessionMode {
        case .chat: "mac.pane.switch_to_terminal"
        case .terminal: "mac.pane.switch_to_chat"
        case nil: "mac.pane.toggle_view"
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("sessions.new") { newSession?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newSession == nil)
            Button("mac.pair_machine") { pairMachine?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(pairMachine == nil)
        }
        // The system Find group is removed at launch (CorralAppDelegate) so
        // ⌘F and ⌘E belong to these commands, as on the Mac.
        CommandGroup(after: .textEditing) {
            Button("sessions.search") { searchSessions?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(searchSessions == nil)
        }
        CommandMenu("mac.menu.session") {
            Button(toggleViewTitle) { toggleSessionMode?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(toggleSessionMode == nil)
        }
        SidebarCommands()
    }
}

/// A menu command's action published by the focused scene. Equality is the
/// publisher's identity, not the closure, so routine view updates do not
/// invalidate the menu bar; the closure only writes the publisher's own state.
struct CorralCommandAction: Equatable {
    let id: String
    let perform: () -> Void

    func callAsFunction() { perform() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension FocusedValues {
    @Entry var corralNewSession: CorralCommandAction?
    @Entry var corralPairMachine: CorralCommandAction?
    @Entry var corralSearchSessions: CorralCommandAction?
    @Entry var corralToggleSessionMode: CorralCommandAction?
    @Entry var corralFocusedSessionMode: SessionDetailMode?
}
#endif
