import SwiftUI

/// One split pane: header and chat or terminal body. The pane owns the
/// session's conversation so switching between chat and terminal keeps it
/// live (and its prompts card current) in both views.
struct MacPaneView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macPaneLifetime) private var lifetime
    let session: SessionSummary
    let metadataStore: SessionListStore?
    var allowsClose = true
    var autoFocusComposer = false

    @State private var store: ConversationStore?
    @State private var bodySize: CGSize = .zero
    @State private var paneFrame: CGRect = .zero
    @State private var terminalVisited = false
    @State private var terminalPromptRequest: TerminalPromptRequest?
    @State private var terminalHistoryPreview = false
    @State private var chatVisited = false
    /// Bumped on every (re)appearance; a disappear-triggered stop only runs
    /// when no reappearance has happened since, so a fast close→reopen can
    /// never stop the revived store from underneath its new start().
    @State private var visibilitySerial = 0

    init(session: SessionSummary, metadataStore: SessionListStore?, allowsClose: Bool = true,
         autoFocusComposer: Bool = false, retainedStore: ConversationStore? = nil,
         retainedBodySize: CGSize = .zero) {
        self.session = session
        self.metadataStore = metadataStore
        self.allowsClose = allowsClose
        self.autoFocusComposer = autoFocusComposer
        _store = State(initialValue: retainedStore)
        _bodySize = State(initialValue: retainedBodySize)
    }

    /// Read focus from the workspace directly. A cached copy on the pane's
    /// lifetime only refreshed when the surrounding split rebuilt, so a click
    /// or composer focus could leave the focused header in its inactive gray
    /// (owner report 2026-10-17).
    private var isFocused: Bool { workspace.focusedKey == session.key }
    private var mode: MacWorkspace.PaneMode { workspace.mode(for: session.key) }

    // MARK: - Focus guidance (design: Visual guidance pass)

    /// Another pane in the split holds the focus, so this composer steps back.
    private var composerRecedes: Bool {
        guard workspace.paneKeys.count > 1,
              let focused = workspace.focusedKey, focused != session.key else { return false }
        return workspace.paneKeys.contains(focused)
    }

    // MARK: - Prompts card (design: Prompts card)

    private var prompts: [RichMessage] {
        store?.userPrompts ?? []
    }

    /// Both presentations center in the same space beside an open prompts card.
    private var cardFitsBeside: Bool {
        bodySize.width - MacPromptsCard.reserve * interfaceScale >= MacPromptsCard.minimumReadingWidth * interfaceScale
    }

    private var cardOpen: Bool {
        workspace.promptsOpen[session.key] ?? (mode == .terminal || cardFitsBeside)
    }

    private var reservesCardMargin: Bool {
        cardFitsBeside && cardOpen && !prompts.isEmpty
    }

    @ViewBuilder
    private var promptsCard: some View {
        let prompts = prompts
        if !prompts.isEmpty, bodySize.width > 0 {
            MacPromptsCard(
                prompts: prompts,
                isOpen: promptsOpenBinding,
                width: min(MacPromptsCard.width * interfaceScale, bodySize.width - Space.md * 2 * interfaceScale),
                overContent: !cardFitsBeside,
                onTerminal: mode == .terminal,
                // Over content the card covers at most about half the pane.
                maxListHeight: max(120, bodySize.height * (cardFitsBeside ? 0.7 : 0.45) - 56),
                onSelect: { prompt in
                    if mode == .terminal {
                        terminalPromptRequest = TerminalPromptRequest(seq: prompt.seq, generation: store?.promptHistoryGeneration ?? 0)
                    } else {
                        workspace.scrollToPrompt(ConversationTimelineItem.message(prompt).id, in: session.key)
                    }
                }
            )
            .interfacePadding(.top, Space.md)
            .interfacePadding(.trailing, Space.md)
        }
    }

    private var promptsOpenBinding: Binding<Bool> {
        Binding(
            get: { cardOpen },
            set: { workspace.promptsOpen[session.key] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPaneHeader(
                session: session,
                isFocused: isFocused,
                allowsClose: allowsClose,
                promptsCount: bodySize.width > 0 ? prompts.count : 0,
                promptsOpen: promptsOpenBinding
            )
            Divider()
            content
                // Beside the conversation the card takes the trailing margin and
                // either presentation shifts aside; elsewhere it floats over content.
                // Animated only when the person opens or closes the card (its
                // buttons use withAnimation). A split change that makes the card
                // stop fitting must not interpolate the reading width: that
                // reflowed every visible message on every frame of the change.
                .interfacePadding(.trailing, reservesCardMargin ? MacPromptsCard.reserve : 0)
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                // The strip behind the floating card is pane background too:
                // terminal keeps its emulator black, chat keeps grouped gray.
                .background(mode == .terminal ? Color(nsColor: TerminalAppearance.background) : Color(.systemGroupedBackground))
                .overlay(alignment: .topTrailing) { promptsCard }
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    bodySize = $0
                    workspace.paneSurfaces.existingEntry(for: session.key)?.bodySize = $0
                }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            paneFrame = frame
            // A retained hosting view has its own global coordinate space;
            // its native mount publishes the window-relative frame.
            if lifetime == nil { workspace.paneFrames[session.key] = frame }
        }
        .onAppear { prepareStore() }
        .onChange(of: mode, initial: true) { _, current in
            if current == .terminal && !terminalVisited { terminalVisited = true }
            if current == .chat && !chatVisited { chatVisited = true }
        }
        #if DEBUG
        .onChange(of: prompts.count, initial: true) { _, _ in
            MacInteractionInspectionPrompts.shared[session.key] = prompts
        }
        .task { await MacPromptJumpInspection.run(key: session.key, workspace: workspace) { prompts } }
        .task { await MacCopyInspection.run(key: session.key, workspace: workspace) }
        .task { await MacTerminalReturnInspection.inspectColdChatIfRequested(appModel: appModel) }
        .task { await MacSelectionDragInspection.run(key: session.key, workspace: workspace) }
        #endif
        .background {
            MacPaneConnection(sessionKey: session.key, lifetime: lifetime, store: store,
                              prepareStore: { prepareStore() }, resetStore: { store = nil }) {
                workspace.paneFrames[session.key] =
                    workspace.paneSurfaces.existingEntry(for: session.key)?.lastFrame ?? paneFrame
                metadataStore?.markReadLocally(key: session.key)
            }
        }
        .onAppear { metadataStore?.markReadLocally(key: session.key) }
        .onDisappear {
            guard lifetime == nil else { return }
            workspace.paneFrames[session.key] = nil
            let owned = store
            let ticket = visibilitySerial
            let key = session.key
            Task { @MainActor in
                // A reappearance bumps the serial in prepareStore(); skip the
                // stop so it cannot land after the new start(). The key check
                // covers a fresh view instance (new @State) reopening the same
                // retained store while this task was in flight.
                guard ticket == visibilitySerial,
                      !workspace.paneKeys.contains(key) else { return }
                await owned?.stop()
            }
        }
    }

    /// The terminal sits beneath the chat at a fixed position once visited, so
    /// its native emulator keeps its screen while chat is shown. It hides
    /// itself natively; SwiftUI visibility modifiers here would re-insert the
    /// AppKit view and force a synchronous window layout on every switch.
    @ViewBuilder
    private var content: some View {
        ZStack {
            if mode == .terminal || terminalVisited {
                MacTerminalPane(
                    session: session,
                    isFocused: isFocused && mode == .terminal && !terminalHistoryPreview,
                    isPresented: mode == .terminal && !terminalHistoryPreview && (lifetime?.isPresented ?? true),
                    promptRequest: terminalPromptRequest,
                    onHistoryPreview: { seq in
                        terminalHistoryPreview = true
                        workspace.scrollToPrompt("message-\(seq)", in: session.key)
                    }
                )
                .environment(\.conversationScrollReadAction, acknowledgeTerminalScrollRead)
                .id(session.key)
            }
            if mode == .chat || chatVisited || terminalHistoryPreview {
                if let store {
                    MacChatSurface(isPresented: mode == .chat || terminalHistoryPreview) {
                        SessionDetailView(
                            session: session,
                            autoFocusComposer: autoFocusComposer,
                            metadataStore: metadataStore,
                            injectedStore: store,
                            composerFocusRequest: workspace.composerFocusRequest(for: session.key),
                            onComposerFocusChange: { focused in
                                if focused { workspace.composerDidGainFocus(session.key) }
                            },
                            scrollRequest: workspace.scrollRequests[session.key],
                            historyPreview: mode == .terminal && terminalHistoryPreview,
                            onReturnToTerminal: { terminalHistoryPreview = false },
                            onDidCreateSession: { created in workspace.openCreated(created, asPane: true) }
                        )
                        .environment(\.macConversationTextDocument, workspace.paneSurfaces.entry(for: session.key).textDocument())
                        .id(ObjectIdentifier(store))
                        .environment(\.composerRecedes, composerRecedes)
                        .animation(MacMotion.state, value: composerRecedes)
                    }
                } else {
                    ProgressView().interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func acknowledgeTerminalScrollRead() {
        guard let store, metadataStore?.markReadLocally(key: session.key) == true else { return }
        Task { await store.markRead() }
    }

    @discardableResult
    private func prepareStore() -> ConversationStore? {
        visibilitySerial &+= 1
        if let store {
            lifetime?.bind(store)
            #if DEBUG
            if MacSessionSwitchInspection.enabled {
                MacSessionSwitchInspection.stores[session.key] = store
                if MacSessionSwitchInspection.preparationMs[session.key] == nil {
                    MacSessionSwitchInspection.preparationMs[session.key] = 0
                }
            }
            #endif
            return store
        }
        #if DEBUG
        let preparationStart = ContinuousClock.now
        #endif
        let entry = workspace.paneSurfaces.entry(for: session.key)
        let currentIdentity = appModel.client.map(ObjectIdentifier.init)
        // Rebuilds reuse the retained conversation when it still belongs to
        // the current connection; a replaced client gets a fresh store so the
        // pane resubscribes instead of idling on a dead connection.
        if let retained = entry.store,
           retained.clientIdentity == currentIdentity || appModel.client == nil {
            store = retained
            lifetime?.bind(retained)
            #if DEBUG
            if MacSessionSwitchInspection.enabled {
                MacSessionSwitchInspection.stores[session.key] = retained
                if MacSessionSwitchInspection.preparationMs[session.key] == nil {
                    MacSessionSwitchInspection.preparationMs[session.key] = 0
                }
            }
            #endif
            return retained
        }
        let hostID = appModel.selectedHost?.hostID ?? appModel.connectedHostID ?? ""
        let created = ConversationStore(
            sessionKey: session.key,
            client: appModel.client,
            live: session.live,
            attention: session.attention,
            hostID: hostID
        )
        if let metadataStore {
            created.onSessionMetadata = { summary, revision in
                metadataStore.applySessionEvent(summary, revision: revision)
            }
        }
        store = created
        entry.store = created
        lifetime?.bind(created)
        #if DEBUG
        if MacSessionSwitchInspection.enabled {
            MacSessionSwitchInspection.stores[session.key] = created
            MacSessionSwitchInspection.preparationMs[session.key] = MacSessionSwitchInspection.milliseconds(
                preparationStart.duration(to: .now)
            )
        }
        #endif
        return created
    }
}

/// Pane title bar: one dominant title, attention dots, the native view
/// switch, the session menu and Close. Focus is the header's surface, never a
/// focus ring or a tint on the reading area (design: Pane header composition).
struct MacPaneHeader: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let session: SessionSummary
    let isFocused: Bool
    var allowsClose = true
    var promptsCount = 0
    @Binding var promptsOpen: Bool

    @State private var runtimes: [RuntimeEntry] = []

    var body: some View {
        ViewThatFits(in: .horizontal) {
            singleLine
            stacked
        }
        .interfaceControlSize(.small)
        .interfacePadding(.horizontal, Space.md)
        .interfaceFrame(minHeight: 48)
        .background(headerSurface)
        .animation(MacMotion.state, value: isFocused)
        .animation(MacMotion.state, value: SessionPresentation.activityMarker(for: session))
        .animation(MacMotion.state, value: SessionPresentation.hasUnread(for: session))
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focus(session.key)
            workspace.requestKeyFocus(session.key)
        }
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .task { await loadRuntimes() }
    }

    private var singleLine: some View {
        HStack(spacing: 0) {
            // The title starts at the header's leading edge, flush with the
            // conversation below it. A fixed leading dot slot pushed it in
            // by 26 points even with no dots (owner report 2026-10-17).
            titleText
                .layoutPriority(1)
            statusDotsView
            Spacer(minLength: Space.sm)
            actions
                .fixedSize()
        }
    }

    /// Large interface zoom in a narrow split: keep every action reachable.
    /// Normal use stays on `singleLine`; the owner requires one line.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
            HStack(spacing: 0) {
                titleText
                    .layoutPriority(1)
                statusDotsView
                Spacer(minLength: 0)
            }
            actions
                .interfaceFrame(maxWidth: .infinity, alignment: .trailing)
        }
        .interfacePadding(.vertical, 6)
    }

    private var titleText: some View {
        Text(verbatim: SessionPresentation.displayTitle(for: session))
            .interfaceFont(.system(size: 15, weight: isFocused ? .semibold : .medium))
            .foregroundStyle(isFocused ? Color.primary : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(Text(verbatim: titleHelp))
            .accessibilityLabel(Text(verbatim: SessionPresentation.displayTitle(for: session)))
    }

    /// Attention dots follow the title text, so the title itself never moves.
    @ViewBuilder
    private var statusDotsView: some View {
        let dots = statusDots
        if !dots.isEmpty {
            HStack(spacing: 4 * interfaceScale) {
                ForEach(dots.indices, id: \.self) { index in
                    Circle()
                        .fill(dots[index])
                        .interfaceFrame(width: 7, height: 7)
                        .transition(.opacity)
                }
            }
            .interfacePadding(.leading, 6)
            .accessibilityHidden(true)
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            MacPaneViewSwitch(mode: modeBinding)
                .fixedSize()
            sessionMenu
                .interfacePadding(.leading, Space.md)
            if allowsClose {
                closeButton
                    .interfacePadding(.leading, Space.sm)
            }
        }
        .fixedSize()
    }

    /// Focus takes the brighter surface in both appearances: white over the
    /// grouped gray in light, the raised gray over the page in dark.
    private var headerSurface: Color {
        let page = Color(.systemGroupedBackground)
        let raised = Color(.secondarySystemGroupedBackground)
        if colorScheme == .dark {
            return isFocused ? raised : page
        }
        return isFocused ? page : raised
    }

    private var modeBinding: Binding<MacWorkspace.PaneMode> {
        Binding(
            get: { workspace.mode(for: session.key) },
            set: { mode in
                workspace.setMode(mode, for: session.key)
                workspace.focus(session.key)
                workspace.requestKeyFocus(session.key)
            }
        )
    }

    private var titleHelp: String {
        let title = SessionPresentation.displayTitle(for: session)
        let agent = Palette.runtimeDisplayName(session.runtime)
        let project = SessionPresentation.projectName(from: session)
        let path = SessionPresentation.fullWorkspacePath(from: session)
        var lines = [title]
        let identity = [agent, project].filter { !$0.isEmpty }.joined(separator: " · ")
        if !identity.isEmpty { lines.append(identity) }
        if !path.isEmpty { lines.append(path) }
        return lines.joined(separator: "\n")
    }

    private var closeButton: some View {
        Button {
            workspace.closePane(session.key)
        } label: {
            Image(systemName: "xmark")
                .interfaceFont(.system(size: 11, weight: .semibold))
                .interfaceFrame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.secondary)
        .help(Text("mac.pane.close"))
        .accessibilityLabel(Text("mac.pane.close"))
    }

    /// The prompt card's collapsed home is the session menu; opening or
    /// closing it keeps the card's disclosure animation.
    private var promptsBinding: Binding<Bool> {
        Binding(
            get: { promptsOpen },
            set: { open in
                withAnimation(MacMotion.disclosure(reduceMotion: reduceMotion)) { promptsOpen = open }
            }
        )
    }

    private var sessionMenu: some View {
        Menu {
            if promptsCount > 0 || promptsOpen {
                Toggle(isOn: promptsBinding) {
                    Text("mac.prompts.title \(promptsCount)")
                }
                Divider()
            }
            Button {
                Task { await workspace.togglePin(session.key) }
            } label: {
                Label("mac.session.pin_toggle", systemImage: "pin")
            }
            Divider()
            Button {
                Task { await workspace.fork(session) }
            } label: {
                Label("session.actions.copy", systemImage: "doc.on.doc")
            }
            Menu {
                ForEach(SessionActionsMenu.handoffTargets(from: runtimes)) { runtime in
                    Button(runtime.name ?? runtime.id) {
                        Task { await workspace.handoff(session, to: runtime.id) }
                    }
                }
            } label: {
                Label("mac.session.continue_with", systemImage: "arrow.triangle.branch")
            }
            .disabled(runtimes.isEmpty)
            Button {
                Task { await workspace.restart(session.key) }
            } label: {
                Label("session.actions.restart", systemImage: "arrow.clockwise")
            }
            .disabled(appModel.client?.hostCapabilities.sessionRestart != true)
            if session.live {
                Button {
                    Task { await workspace.stop(session.key) }
                } label: {
                    Label("sessions.action.stop", systemImage: "stop.fill")
                }
            }
            Divider()
            Button {
                PlatformPasteboard.copy(SessionPresentation.fullWorkspacePath(from: session))
            } label: {
                Label("session.workspace.copy_path", systemImage: "folder")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Color.secondary)
                .interfaceFrame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A borderless menu draws its label in the tint, not the foreground style.
        .tint(Color(nsColor: .secondaryLabelColor))
        .fixedSize()
        .disabled(SessionActionsMenu.isReadonly(access: appModel.connectedAccess))
        .help(Text("session.actions.menu"))
        .accessibilityIdentifier("corral.session.actions")
    }

    /// Activity dot first, then the independent red unread overlay.
    private var statusDots: [Color] {
        var dots: [Color] = []
        if let activity = SessionPresentation.activityMarker(for: session) {
            dots.append(markerColor(activity))
        }
        if SessionPresentation.hasUnread(for: session) {
            dots.append(markerColor(.unread))
        }
        return dots
    }

    private func markerColor(_ marker: SessionPresentation.StatusMarker) -> Color {
        switch marker {
        case .waiting: Palette.attentionWaiting
        case .working, .recent: Palette.attentionWorking
        case .unread: Palette.attentionUnread
        }
    }

    private func loadRuntimes() async {
        // The workspace already loads the runtime list once per connection;
        // per-pane fetch is only a fallback for headers mounted before it.
        if !workspace.runtimes.isEmpty {
            runtimes = workspace.runtimes
            return
        }
        guard runtimes.isEmpty, let client = appModel.client,
              let data = try? await client.call(WireProtocol.mRuntimesList) as? [String: Any],
              let items = data["runtimes"] as? [[String: Any]] else { return }
        runtimes = items.compactMap { try? RemoteJSONDecoder.decode(RuntimeEntry.self, from: $0) }.filter(\.isActive)
    }
}

extension EnvironmentValues {
    /// Session keys of the panes currently on screen (split or board page).
    @Entry var macVisiblePaneKeys: [String] = []
    /// Sidebar minute clock, ticked once per minute by the sidebar itself so
    /// a hundred rows do not run a hundred per-minute timers.
    @Entry var sidebarNow: Date = Date()
}

/// Identity of the connection a pane's subscriptions belong to.
struct PaneConnectionKey: Hashable {
    let sessionKey: String
    let client: ObjectIdentifier?
    let ready: Bool
}

extension ConversationStore {
    var clientIdentity: ObjectIdentifier? { boundClient.map(ObjectIdentifier.init) }
}

/// Keep subscription observation outside the expensive conversation layout.
private struct MacPaneConnection: View {
    @Environment(AppModel.self) private var appModel
    let sessionKey: String
    let lifetime: MacPaneLifetime?
    let store: ConversationStore?
    let prepareStore: () -> ConversationStore?
    let resetStore: () -> Void
    let onPresented: () -> Void

    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: PaneConnectionKey(sessionKey: sessionKey, client: appModel.clientIdentity,
                                        ready: isReady && (lifetime?.isPresented ?? true))) {
                guard isReady, lifetime?.isPresented ?? true else { return }
                await lifetime?.waitForSuspension()
                guard !Task.isCancelled, lifetime?.isPresented ?? true else { return }
                if let store, store.clientIdentity != appModel.clientIdentity {
                    await store.stop()
                    resetStore()
                }
                guard let owned = prepareStore() else { return }
                async let readMark: Void = owned.markRead()
                await owned.start()
                for attempt in 1...4 where owned.loadError != nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                    await owned.retry()
                }
                await readMark
            }
            .onChange(of: lifetime?.isPresented) { _, presented in
                if presented == true { onPresented() }
            }
    }
}


/// Retain the chat's native table, row hosts, selection and composer while the
/// terminal is presented. Reuses MacPaneSurface's native hiding/deferred-layout
/// boundary; SwiftUI visibility modifiers would remount its native children.
private struct MacChatSurface<Content: View>: NSViewRepresentable {
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.macPaneLifetime) private var lifetime
    var isPresented: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> MacPaneHostingView {
        let view = MacPaneHostingView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MacPaneHostingView, context: Context) {
        if !isPresented, let responder = view.window?.firstResponder as? NSView,
           responder.isDescendant(of: view) {
            view.window?.makeFirstResponder(nil)
        }
        view.isHidden = !isPresented
        guard isPresented else { return }
        let env = context.environment
        view.rootView = AnyView(content()
            .environment(appModel)
            .environment(workspace)
            .environment(\.macPaneLifetime, lifetime)
            .environment(\.interfaceScale, env.interfaceScale)
            .environment(\.colorScheme, env.colorScheme)
            .environment(\.locale, env.locale)
            .environment(\.calendar, env.calendar)
            .environment(\.timeZone, env.timeZone)
            .environment(\.layoutDirection, env.layoutDirection)
            .environment(\.font, env.font)
            .environment(\.controlSize, env.controlSize)
            .environment(\.dynamicTypeSize, env.dynamicTypeSize))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacPaneHostingView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}
