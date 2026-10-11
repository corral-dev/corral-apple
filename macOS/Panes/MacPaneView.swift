import SwiftUI

/// One split pane: header and chat or terminal body. The pane owns the
/// session's conversation so switching between chat and terminal keeps it
/// live (and its prompts card current) in both views.
struct MacPaneView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macVisiblePaneKeys) private var visiblePaneKeys
    @Environment(\.macPaneLifetime) private var lifetime
    let session: SessionSummary
    let metadataStore: SessionListStore?
    var allowsClose = true
    var autoFocusComposer = false

    @State private var store: ConversationStore?
    @State private var bodySize: CGSize = .zero
    @State private var paneFrame: CGRect = .zero

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

    private var isFocused: Bool { lifetime?.isFocused ?? (workspace.focusedKey == session.key) }
    private var mode: MacWorkspace.PaneMode { workspace.mode(for: session.key) }

    // MARK: - Focus guidance (design: Visual guidance pass)

    /// Another pane is on screen beside this one.
    private var hasPeers: Bool { visiblePaneKeys.count > 1 }

    /// Another visible pane holds the focus, so this composer steps back.
    private var composerRecedes: Bool {
        guard hasPeers, !isFocused else { return false }
        if let lifetime { return lifetime.hasFocusedPeer }
        return workspace.focusedKey.map { visiblePaneKeys.contains($0) } ?? false
    }

    // MARK: - Prompts card (design: Prompts card)

    private var prompts: [RichMessage] {
        store?.userPrompts ?? []
    }

    /// Chat view with room for a reading column beside the card. Terminal view
    /// never gives up width: its width sets the host terminal size.
    private var cardFitsBeside: Bool {
        mode == .chat && bodySize.width - MacPromptsCard.reserve * interfaceScale >= MacPromptsCard.minimumReadingWidth * interfaceScale
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
                    guard mode == .chat else { return }
                    workspace.scrollToPrompt(ConversationTimelineItem.message(prompt).id, in: session.key)
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
                showsFocusRule: isFocused && hasPeers,
                allowsClose: allowsClose,
                promptsCount: bodySize.width > 0 ? prompts.count : 0,
                promptsOpen: promptsOpenBinding
            )
            Divider()
            // Chat and terminal crossfade, softening the light-to-dark jump.
            content
                .animation(MacMotion.crossfade, value: mode)
                // Beside the conversation the card takes the trailing margin and
                // the chat shifts aside; elsewhere it floats over the content.
                // Animated only when the person opens or closes the card (its
                // buttons use withAnimation). A split change that makes the card
                // stop fitting must not interpolate the reading width: that
                // reflowed every visible message on every frame of the change.
                .interfacePadding(.trailing, reservesCardMargin ? MacPromptsCard.reserve : 0)
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
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
        #if DEBUG
        .onChange(of: prompts.count, initial: true) { _, _ in
            MacInteractionInspectionPrompts.shared[session.key] = prompts
        }
        .task { await MacPromptJumpInspection.run(key: session.key, workspace: workspace) { prompts } }
        .task { await MacCopyInspection.run(key: session.key, workspace: workspace) }
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
            Task { await owned?.stop() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .chat:
            if let store {
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
                    onDidCreateSession: { created in workspace.openCreated(created, asPane: true) }
                )
                .environment(\.macConversationTextDocument, workspace.paneSurfaces.entry(for: session.key).textDocument())
                .id(ObjectIdentifier(store))
                .environment(\.composerRecedes, composerRecedes)
                .animation(MacMotion.state, value: composerRecedes)
                .transition(.opacity)
            } else {
                ProgressView().interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .terminal:
            MacTerminalPane(session: session, isFocused: isFocused)
                .environment(\.conversationScrollReadAction, acknowledgeTerminalScrollRead)
                .id(session.key)
                .transition(.opacity)
        }
    }

    private func acknowledgeTerminalScrollRead() {
        guard let store, metadataStore?.markReadLocally(key: session.key) == true else { return }
        Task { await store.markRead() }
    }

    @discardableResult
    private func prepareStore() -> ConversationStore? {
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

/// Pane title bar: identity, prompts, chat/terminal switch, session menu and
/// close. Beside other panes the focused one carries an accent rule under its
/// header, never a focus ring or tint (baseline A4).
struct MacPaneHeader: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: SessionSummary
    let isFocused: Bool
    var showsFocusRule = false
    var allowsClose = true
    var promptsCount = 0
    @Binding var promptsOpen: Bool

    @State private var runtimes: [RuntimeEntry] = []

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm * interfaceScale) {
                identity
                if promptsCount > 0 { promptsButton }
                viewPicker
                sessionMenu
                closeButton
            }
            VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                identity
                HStack(spacing: Space.xs * interfaceScale) {
                    if promptsCount > 0 { promptsButton.labelStyle(.iconOnly) }
                    Spacer(minLength: 0)
                    viewPicker
                    sessionMenu
                    closeButton
                }
            }
        }
        .interfaceControlSize(.small)
        .interfacePadding(.horizontal, Space.md)
        .interfacePadding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if showsFocusRule {
                Rectangle()
                    .fill(Palette.accent)
                    .interfaceFrame(height: 2)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(MacMotion.state, value: showsFocusRule)
        .animation(MacMotion.state, value: isFocused)
        .animation(MacMotion.state, value: SessionPresentation.statusMarker(for: session))
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focus(session.key)
            workspace.requestKeyFocus(session.key)
        }
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .task { await loadRuntimes() }
    }

    private var identity: some View {
        HStack(spacing: Space.sm * interfaceScale) {
            if let marker = SessionPresentation.statusMarker(for: session) {
                Circle()
                    .fill(markerColor(marker))
                    .interfaceFrame(width: 7, height: 7)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            // One line, sidebar language (design: Pane header redesign): bare
            // logo, title, then the project in secondary text, which gives way
            // before the title does.
            RuntimeGlyph(runtimeID: session.runtime, size: 16)
            HStack(alignment: .firstTextBaseline, spacing: 6 * interfaceScale) {
                Text(verbatim: SessionPresentation.displayTitle(for: session))
                    .interfaceFont(.body.weight(.semibold))
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(verbatim: SessionPresentation.projectName(from: session))
                    .interfaceFont(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Titles give way to the controls so four panes fit beside the sidebar.
            .interfaceFrame(minWidth: 30, idealWidth: 30, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            .help(Text(verbatim: SessionPresentation.displayTitle(for: session)
                + "\n" + SessionPresentation.fullWorkspacePath(from: session)))
        }
    }

    private var viewPicker: some View {
        Picker("mac.pane.view", selection: Binding(
                get: { workspace.mode(for: session.key) },
                set: {
                    workspace.setMode($0, for: session.key)
                    workspace.focus(session.key)
                    workspace.requestKeyFocus(session.key)
                }
            )) {
                Label("mac.pane.chat", systemImage: "bubble.left.and.text.bubble.right").tag(MacWorkspace.PaneMode.chat)
                Label("mac.pane.terminal", systemImage: "terminal").tag(MacWorkspace.PaneMode.terminal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
            // Neutral selected segment: green in the header is kept for status
            // and the focus rule, not for a view switch.
            .tint(Color(nsColor: .tertiaryLabelColor))
            .fixedSize()
            .help(Text("mac.pane.view.help"))
    }

    @ViewBuilder
    private var closeButton: some View {
            if allowsClose {
                Button {
                    workspace.closePane(session.key)
                } label: {
                    Image(systemName: "xmark")
                        .interfaceFont(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.secondary)
                .help(Text("mac.pane.close"))
                .accessibilityLabel(Text("mac.pane.close"))
            }
    }

    /// Collapsed home of the Your prompts card, so nothing floats over the
    /// conversation while it is closed; also closes the open card.
    private var promptsButton: some View {
        Button {
            withAnimation(MacMotion.disclosure(reduceMotion: reduceMotion)) { promptsOpen.toggle() }
        } label: {
            Label {
                Text(verbatim: promptsCount.formatted())
                    .interfaceFont(.subheadline.monospacedDigit())
            } icon: {
                Image(systemName: "text.bubble")
                    .symbolVariant(promptsOpen ? .fill : .none)
            }
            // Plain grey: `.secondary` inside a borderless button resolves against the accent tint.
            .foregroundStyle(promptsOpen ? Palette.accent : Color.secondary)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(Text(promptsOpen ? "mac.prompts.hide" : "mac.prompts.show"))
        .accessibilityLabel(Text("mac.prompts.title \(promptsCount)"))
        .accessibilityAddTraits(promptsOpen ? .isSelected : [])
    }

    private var sessionMenu: some View {
        Menu {
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
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A borderless menu draws its label in the tint, not the foreground style.
        .tint(Color(nsColor: .secondaryLabelColor))
        .fixedSize()
        .disabled(SessionActionsMenu.isReadonly(access: appModel.connectedAccess))
        .help(Text("session.actions.menu"))
    }

    private func markerColor(_ marker: SessionPresentation.StatusMarker) -> Color {
        switch marker {
        case .waiting: Palette.attentionWaiting
        case .working, .recent: Palette.attentionWorking
        case .unread: Palette.attentionUnread
        }
    }

    private func loadRuntimes() async {
        guard runtimes.isEmpty, let client = appModel.client,
              let data = try? await client.call(WireProtocol.mRuntimesList) as? [String: Any],
              let items = data["runtimes"] as? [[String: Any]] else { return }
        runtimes = items.compactMap { try? RemoteJSONDecoder.decode(RuntimeEntry.self, from: $0) }.filter(\.isActive)
    }
}

extension EnvironmentValues {
    /// Session keys of the panes currently on screen (split or board page).
    @Entry var macVisiblePaneKeys: [String] = []
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
